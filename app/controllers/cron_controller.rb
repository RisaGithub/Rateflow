# Refresh endpoints for an external scheduler. GET on purpose — many free
# schedulers can only GET — guarded by a shared token from ENV["CRON_TOKEN"],
# never by cookies. Everything runs inside the request, no background queues.
class CronController < ApplicationController
  THROTTLE = 10.minutes

  # A dedicated store instead of Rails.cache: the token check must stay
  # brute-force-limited even where the app cache is a null store (tests).
  RATE_LIMIT_STORE = ActiveSupport::Cache::MemoryStore.new

  rate_limit to: 20, within: 1.minute, store: RATE_LIMIT_STORE,
             with: -> { render json: { error: "Too many requests, try again in a minute" }, status: :too_many_requests }
  before_action :authenticate!

  # GET /cron/refresh?token=… — rates for the last 14 days from the three API
  # providers (plus the internal forecast re-snapshot inside RatesFetcher).
  # АПЭКОН is not called here: its crawl delay is too slow for this endpoint,
  # and its quote arrives with /cron/forecasts instead.
  def refresh
    return render_skipped("rates") if recently_ran?("rates")

    started = now_ms
    written = RatesFetcher.new.call
    prune_logs_daily
    render json: { status: "ok", kind: "rates", rows_written: written, duration_ms: now_ms - started }
  end

  # GET /cron/forecasts?token=… — one АПЭКОН currency per call (the stalest;
  # the site's 10-second crawl delay makes all four too slow for one request).
  # The same page load also yields today's АПЭКОН quote, stored into rates,
  # plus the cheap internal forecast for every currency.
  def forecasts
    return render_skipped("forecast") if recently_ran?("forecast")

    started = now_ms
    apecon = ForecastsFetcher.new.call
    internal = InternalForecast.new.call
    render json: { status: "ok", kind: "forecast", apecon: apecon,
                   internal_snapshots: internal, duration_ms: now_ms - started }
  end

  private

  # No token configured → the endpoint is off (503), not open to everyone.
  # A wrong token gets a bare 401 with no details.
  def authenticate!
    secret = ENV["CRON_TOKEN"]
    if secret.blank?
      render json: { error: "CRON_TOKEN is not configured" }, status: :service_unavailable
    elsif !ActiveSupport::SecurityUtils.secure_compare(params[:token].to_s, secret)
      render json: { error: "Unauthorized" }, status: :unauthorized
    end
  end

  # The day's first successful refresh also prunes old fetch logs and stale
  # internal snapshots (see LogsPruner) — no separate scheduler needed. The
  # cache marker vanishes on restart, but an extra prune is a cheap no-op.
  def prune_logs_daily
    Rails.cache.fetch("logs-pruned-#{Date.current.iso8601}", expires_in: 25.hours) do
      LogsPruner.new.call
    end
  end

  # The same update finishing less than 10 minutes ago means "skipped" —
  # FetchLog already records every attempt, so no extra state is needed.
  def recently_ran?(kind)
    last_run(kind)&.created_at&.after?(THROTTLE.ago)
  end

  def render_skipped(kind)
    render json: { status: "skipped", kind: kind, last_run_at: last_run(kind).created_at.iso8601 }
  end

  def last_run(kind)
    FetchLog.for_kind(kind).recent.first
  end

  def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
end
