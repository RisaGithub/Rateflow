# Fills the accuracy block without waiting weeks for live forecasts to
# mature: replays our own model over the past two years of CBR history. Every
# replay date sees only the rates that were known by then — no peeking
# forward — and the result is stored as a regular forecast_run with
# captured_at set to that date, so ForecastAccuracy scores it exactly like a
# live snapshot. Backtested numbers measure the model on history, not real
# published predictions — the UI says so next to the figures.
#
# Idempotent: the replay grid is anchored to Mondays (stable no matter which
# day the task runs on), and a run already stored for (currency, captured_at)
# is skipped, so re-running never multiplies snapshots. Long — meant for the
# rake task (forecasts:backtest), not a web request.
class InternalForecastBacktest
  PERIOD = 2.years
  STEP = 7 # days between replayed forecasts

  def initialize(currencies: Rate::CURRENCIES)
    @currencies = currencies
    @model = InternalForecast.new
  end

  # Returns the number of snapshots created.
  def call
    @currencies.sum { |currency| backtest(currency) }
  end

  private

  def backtest(currency)
    series = Rate.for(currency, ForecastAccuracy::FACT_PROVIDER)
                 .chronological.pluck(:on_date, :value)
    return 0 if series.empty?

    grid.count { |as_of| replay(currency, as_of, series) }
  end

  # Every Monday of the last two years, oldest first.
  def grid
    PERIOD.ago.to_date.beginning_of_week.step(Date.current, STEP)
  end

  # Stores the forecast as it would have been made on as_of; false when there
  # was not enough history back then or the snapshot already exists.
  def replay(currency, as_of, series)
    captured_at = as_of.in_time_zone
    known = series.take_while { |date, _| date <= as_of }
    return false if known.size < InternalForecast::WINDOW + 1
    return false if ForecastRun.exists?(provider: "internal", currency: currency, captured_at: captured_at)

    store(currency, captured_at, @model.points_for(*known.transpose))
    true
  end

  # Direct create instead of ForecastRun.store: store dedups against the
  # *latest* snapshot (the live one), and matching it would drag its
  # captured_at back into the past. Idempotency here is the captured_at guard.
  def store(currency, captured_at, points)
    ForecastRun.transaction do
      run = ForecastRun.create!(provider: "internal", currency: currency,
                                captured_at: captured_at, points_count: points.size)
      ForecastPoint.insert_all!(points.map { |p| p.merge(forecast_run_id: run.id) })
    end
  end
end
