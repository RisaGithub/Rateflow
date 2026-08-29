# The dashboard ships as an empty shell: #show touches no table at all, so the
# HTML leaves the server before any query would have started. Everything the
# page draws arrives afterwards — cards and converter rates from #data, the
# chart from GET /series, the teaser from GET /forecasts/data — and a skeleton
# holds every block's box in the meantime.
class DashboardController < ApplicationController
  CACHE_TTL = 10.minutes

  def show
  end

  # One response for the whole top of the page: a summary per currency card
  # (with its sparkline), the rate each card shows for the converter, and the
  # "nothing fetched yet" flag that raises the first-run notice.
  def data
    payload = Rails.cache.fetch(cache_key, expires_in: CACHE_TTL) { Dashboard.new.as_json }
    render json: payload
  end

  private

  # Keyed like /series: the table's max updated_at invalidates the entry the
  # moment a fetch writes a row, without explicit purging.
  def cache_key = [ "dashboard", Rate.maximum(:updated_at)&.to_i ]
end
