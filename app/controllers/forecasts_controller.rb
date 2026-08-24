# JSON forecast snapshots at GET /forecasts/data: all stored versions for one
# currency, so the charts can draw the latest one and play back the history.
# Cached the same way as /series.
class ForecastsController < ApplicationController
  CACHE_TTL = 10.minutes

  def data
    payload = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      ForecastSeries.new(currency: currency, providers: providers).as_json
    end
    render json: payload
  end

  private

  # updated_at moves on every new or refreshed snapshot, so a fresh fetch
  # invalidates every cached slice without explicit purging.
  def cache_key
    [ "forecasts", currency, providers.join("-"), ForecastRun.maximum(:updated_at)&.to_i ]
  end

  def currency
    params[:currency].presence_in(Rate::CURRENCIES) || Rate::CURRENCIES.first
  end

  # Missing param means "every forecast provider"; unknown keys are dropped.
  def providers
    return ForecastRun::PROVIDERS unless params.key?(:provider)

    params[:provider].to_s.split(",") & ForecastRun::PROVIDERS
  end
end
