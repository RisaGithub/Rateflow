# JSON series for the dashboard chart: the page fetches this on every
# currency / period / source switch instead of embedding all data in HTML.
class SeriesController < ApplicationController
  def show
    series = RateSeries.new(currency: currency, providers: providers, from: date_param(:from), to: date_param(:to))
    render json: series.as_json
  end

  private

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
