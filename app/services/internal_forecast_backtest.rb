# Fills the accuracy block without waiting weeks for live forecasts to
# mature: replays our own model day by day over past CBR history. Every
# replay date sees only the rates that were known by then — no peeking
# forward — and the result is stored as a regular forecast_run with
# captured_at set to that date, so ForecastAccuracy scores it exactly like a
# live snapshot. A daily grid over a 7-day horizon means every horizon date
# collects a snapshot from each of the preceding days — the revision chart
# and the 1–6 day accuracy buckets get real data. Backtested numbers measure
# the model on history, not real published predictions — the UI says so next
# to the figures.
#
# Idempotent: the replay grid is counted from a fixed calendar date (stable
# no matter which day the task runs on), and a run already stored for
# (currency, captured_at) is skipped, so re-running never multiplies
# snapshots. Meant for the rake task (forecasts:backtest), not a web request.
class InternalForecastBacktest
  DAYS = 180 # default replay depth
  EPOCH = Date.new(2000, 1, 3) # a Monday; grid dates are counted from here

  def initialize(currencies: Rate::CURRENCIES, from: DAYS.days.ago.to_date, step: 1)
    @currencies = currencies
    @from = from
    @step = step
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

  # Every step-th day since EPOCH that falls between from and today, oldest
  # first — anchored to the calendar, so tomorrow's run lands on the same grid.
  def grid
    start = @from + (EPOCH - @from).to_i % @step
    start.step(Date.current, @step)
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
