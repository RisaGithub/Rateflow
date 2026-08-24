# JSON series for the dashboard chart: the page fetches this on every
# currency / period / source switch instead of embedding all data in HTML.
class SeriesController < ApplicationController
  CACHE_TTL = 10.minutes

  def show
    payload = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) do
      RateSeries.new(currency: currency, providers: providers, from: date_param(:from), to: date_param(:to)).as_json
    end
    render json: payload
  end

  private

  # Keyed by the query itself plus the table's max updated_at, so a fresh
  # fetch invalidates every cached slice without explicit purging.
  def cache_key
    [ "series", currency, providers.join("-"), date_param(:from), date_param(:to), Rate.maximum(:updated_at)&.to_i ]
  end

  def currency
    params[:currency].presence_in(Rate::CURRENCIES) || Rate::CURRENCIES.first
  end

  # Missing param means "all providers"; unknown keys are silently dropped.
  def providers
    return Rate::PROVIDERS unless params.key?(:providers)

    params[:providers].to_s.split(",") & Rate::PROVIDERS
  end

  def date_param(key)
    Date.iso8601(params[key]) if params[key].present?
  rescue Date::Error
    nil
  end
end
