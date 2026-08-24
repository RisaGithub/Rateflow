# Pulls one АПЭКОН forecast snapshot per call and stores it via
# ForecastRun.store (which dedups identical snapshots).
#
# АПЭКОН is slow by design — robots.txt demands a 10-second pause between
# requests, so refreshing all currencies at once would hold a web request for
# ~40 seconds. Instead each call updates exactly one currency, the one whose
# snapshot is the oldest; a scheduler hitting the endpoint a few times a day
# rotates through all of them. A currency refreshed less than a day ago is
# never re-fetched (не чаще раза в сутки на валюту).
class ForecastsFetcher
  MIN_AGE = 24.hours

  def initialize(provider: Providers::Apecon.new, currencies: Rate::CURRENCIES)
    @provider = provider
    @currencies = currencies
  end

  # Returns a summary hash: { status:, currency:, points: } or { status: "fresh" }.
  # Any provider failure is recorded in FetchLog and reported, never raised.
  def call
    currency = stalest_currency
    return { status: "fresh" } unless currency

    started = now_ms
    result = @provider.fetch_forecast(currency)
    run = ForecastRun.store(provider: @provider.key, currency: currency,
                            points: result.points, source_url: result.source_url)
    log(started, ok: true, status: result.http_status, count: result.points.size)
    { status: "ok", currency: currency, points: run.points_count, captured_at: run.captured_at }
  rescue Providers::Error => e
    log(started, ok: false, status: e.http_status, error: e.message)
    { status: "error", currency: currency, error: e.message }
  rescue StandardError => e
    log(started, ok: false, error: "#{e.class}: #{e.message}")
    { status: "error", currency: currency, error: e.message }
  end

  private

  # The currency with the oldest snapshot; never-fetched currencies win
  # outright, and one refreshed less than MIN_AGE ago is not due at all.
  def stalest_currency
    last = ForecastRun.where(provider: @provider.key, currency: @currencies)
                      .group(:currency).maximum(:captured_at)
    missing = @currencies.find { |c| last[c].nil? }
    return missing if missing

    currency, captured_at = last.min_by { |_, at| at }
    currency if captured_at < MIN_AGE.ago
  end

  def log(started, ok:, status: nil, count: 0, error: nil)
    FetchLog.create!(
      provider: @provider.key, kind: "forecast", ok: ok, http_status: status,
      duration_ms: now_ms - started, records_count: count, error_message: error&.truncate(1000)
    )
  end

  def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
end
