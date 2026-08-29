# The Прогнозы page plus the two payloads it fills itself from: JSON forecast
# snapshots at GET /forecasts/data — stored versions for one currency, so the
# charts can draw the latest one and play back the history — and the accuracy
# section's HTML at GET /forecasts/accuracy. Both cached the same way as /series.
class ForecastsController < ApplicationController
  CACHE_TTL = 10.minutes

  # The Прогнозы page is a shell of skeletons and touches no table: the charts
  # and the snapshot table fill from #data, the accuracy block from #accuracy,
  # and the "fresh deploy" notice rides along in #data's `empty` flag.
  def show
  end

  def data
    return render json: ForecastSeries.run_as_json(ForecastRun.find(params[:run])) if params[:run]

    payload = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      ForecastSeries.new(currency: currency, providers: providers, latest_only: latest_only?, from: from, to: to).as_json
    end
    render json: payload
  end

  # The accuracy section body for one period, all currencies — fetched when
  # the period switch moves, so the scoring matches what the charts show.
  def accuracy
    html = Rails.cache.fetch([ "forecasts-accuracy", from, to, ForecastRun.maximum(:updated_at)&.to_i ],
                             expires_in: CACHE_TTL) do
      render_to_string(partial: "forecasts/accuracy_groups",
                       locals: { accuracy: accuracy_reports(from, to), scoped: from.present? || to.present? })
    end
    render html: html.html_safe
  end

  private

  def accuracy_reports(from, to = nil)
    Rate::CURRENCIES.index_with { |currency| ForecastAccuracy.new(currency: currency, from: from, to: to).reports }
  end

  # updated_at moves on every new or refreshed snapshot, so a fresh fetch
  # invalidates every cached slice without explicit purging.
  def cache_key
    [ "forecasts", currency, providers.join("-"), latest_only?, from, to, ForecastRun.maximum(:updated_at)&.to_i ]
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

  # ?from=2026-05-26&to=2026-06-26 — the period switch and the custom range;
  # a missing or malformed date means no bound on that side.
  def from = date_param(:from)
  def to = date_param(:to)

  def date_param(key)
    Date.iso8601(params[key].to_s)
  rescue Date::Error
    nil
  end
end
