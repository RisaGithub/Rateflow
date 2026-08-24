# JSON forecast snapshots at GET /forecasts/data: stored versions for one
# currency, so the charts can draw the latest one and play back the history.
# Cached the same way as /series.
class ForecastsController < ApplicationController
  CACHE_TTL = 10.minutes
  # The page opens on the 90-day period; the same default lives in the
  # Stimulus controller's initial state — keep the two in sync.
  DEFAULT_PERIOD_DAYS = 90

  # The Прогнозы page; its charts fetch JSON from #data client-side. Accuracy
  # is pre-rendered per currency for the default period — the shared switches
  # toggle visibility, the period switch refetches #accuracy.
  def show
    @accuracy = accuracy_reports(DEFAULT_PERIOD_DAYS.days.ago.to_date)
  end

  def data
    return render json: ForecastSeries.run_as_json(ForecastRun.find(params[:run])) if params[:run]

    payload = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      ForecastSeries.new(currency: currency, providers: providers, latest_only: latest_only?, from: from).as_json
    end
    render json: payload
  end

  # The accuracy section body for one period, all currencies — fetched when
  # the period switch moves, so the scoring matches what the charts show.
  def accuracy
    html = Rails.cache.fetch([ "forecasts-accuracy", from, ForecastRun.maximum(:updated_at)&.to_i ],
                             expires_in: CACHE_TTL) do
      render_to_string(partial: "forecasts/accuracy_groups", locals: { accuracy: accuracy_reports(from), scoped: from.present? })
    end
    render html: html.html_safe
  end

  private

  def accuracy_reports(from)
    Rate::CURRENCIES.index_with { |currency| ForecastAccuracy.new(currency: currency, from: from).reports }
  end

  # updated_at moves on every new or refreshed snapshot, so a fresh fetch
  # invalidates every cached slice without explicit purging.
  def cache_key
    [ "forecasts", currency, providers.join("-"), latest_only?, from, ForecastRun.maximum(:updated_at)&.to_i ]
  end

  # ?latest=1 keeps only the newest snapshot per provider — enough for the
  # dashboard teaser, a fraction of the full payload.
  def latest_only? = params[:latest].present?

  def currency
    params[:currency].presence_in(Rate::CURRENCIES) || Rate::CURRENCIES.first
  end

  # Missing param means "every forecast provider"; unknown keys are dropped.
  def providers
    return ForecastRun::PROVIDERS unless params.key?(:provider)

    params[:provider].to_s.split(",") & ForecastRun::PROVIDERS
  end

  # ?from=2026-05-26 — the period switch; a missing or malformed date means
  # no filtering at all ("всё время").
  def from
    Date.iso8601(params[:from].to_s)
  rescue Date::Error
    nil
  end
end
