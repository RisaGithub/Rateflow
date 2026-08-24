# Mini admin: database state plus manual refresh buttons. Guarded by HTTP
# Basic with credentials straight from ENV — no gems, no user models. Missing
# credentials switch the page off with a clear 503 instead of letting everyone in.
class AdminController < ApplicationController
  before_action :authenticate!

  def show
    @rate_stats = Rate.group(:provider)
                      .pluck(:provider, Arel.sql("COUNT(*), MIN(on_date), MAX(on_date)"))
                      .to_h { |provider, count, min, max| [ provider, { count: count, from: min, to: max } ] }
    @forecast_stats = ForecastRun.group(:provider)
                                 .pluck(:provider, Arel.sql("COUNT(*), MAX(captured_at)"))
                                 .to_h { |provider, count, last| [ provider, { count: count, last: last } ] }
    @last_update = [ Rate.maximum(:updated_at), ForecastRun.maximum(:updated_at) ].compact.max
    @logs = FetchLog.recent.limit(20)
  end

  # Rates for the last 14 days from every provider (also re-snapshots the
  # internal forecast inside RatesFetcher).
  def refresh_rates
    written = RatesFetcher.new.call
    redirect_to admin_path, notice: "Курсы обновлены: записано #{written} строк."
  end

  # CBR serves a whole year in one request per currency — fast enough for the
  # web. The full archive stays a rake task (bin/rails "rates:backfill[...]").
  def backfill_year
    written = RatesFetcher.new(days: 365, providers: [ Providers::Cbr.new ]).call
    redirect_to admin_path, notice: "История ЦБ РФ за год догружена: записано #{written} строк."
  end

  # One АПЭКОН currency per click — the same rotation the cron endpoint uses.
  def refresh_forecasts
    result = ForecastsFetcher.new.call
    notice = case result[:status]
             when "ok" then "Прогноз АПЭКОН по #{result[:currency]} обновлён: #{result[:points]} точек."
             when "fresh" then "Все прогнозы АПЭКОН свежие (моложе суток) — обновлять нечего."
             else "Прогноз по #{result[:currency]} не обновился: #{result[:error]}"
             end
    redirect_to admin_path, notice: notice
  end

  def rebuild_internal
    count = InternalForecast.new.call
    redirect_to admin_path, notice: "Собственный прогноз пересчитан для #{count} валют."
  end

  private

  def authenticate!
    user, password = ENV["ADMIN_USER"], ENV["ADMIN_PASSWORD"]
    if user.blank? || password.blank?
      render plain: "Админка выключена: задайте ADMIN_USER и ADMIN_PASSWORD в окружении.",
             status: :service_unavailable
    else
      authenticate_or_request_with_http_basic("Rateflow Admin") do |given_user, given_password|
        ActiveSupport::SecurityUtils.secure_compare(given_user, user) &
          ActiveSupport::SecurityUtils.secure_compare(given_password, password)
      end
    end
  end
end
