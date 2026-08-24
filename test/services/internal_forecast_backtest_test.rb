require "test_helper"

class InternalForecastBacktestTest < ActiveSupport::TestCase
  # Daily CBR series covering the given number of days back from today.
  def seed(days:, value: ->(_date) { 80 })
    (days.days.ago.to_date..Date.current).each do |date|
      Rate.create!(provider: "cbr", currency: "USD", on_date: date, value: value.call(date))
    end
  end

  def backtest = InternalForecastBacktest.new(currencies: %w[USD]).call

  test "replays weekly snapshots dated in the past, one run per grid Monday" do
    seed(days: 30)

    created = backtest
    runs = ForecastRun.where(provider: "internal", currency: "USD").chronological

    assert created.positive?
    assert_equal created, runs.count
    assert runs.all? { |r| r.captured_at.monday? && r.captured_at < Time.current }
    assert runs.all? { |r| r.points_count == InternalForecast::HORIZON }
    # A backtested run only looks ahead of its own capture date.
    runs.each do |run|
      assert_operator run.points.minimum(:horizon_date), :>, run.captured_at.to_date
    end
  end

  test "each replay sees only the data known on its date — no peeking forward" do
    # Flat at 50 until a jump to 100 eight days ago; an early replay must not
    # know about the jump.
    seed(days: 40, value: ->(date) { date < 8.days.ago.to_date ? 50 : 100 })

    backtest
    early = ForecastRun.where(provider: "internal", currency: "USD")
                       .where(captured_at: ..15.days.ago).chronological.last

    assert early, "expected a replayed run older than the jump"
    assert early.points.pluck(:value).all? { |v| v == 50 }
  end

  test "re-running creates nothing new and leaves the live snapshot alone" do
    seed(days: 30)
    live = InternalForecast.new(currencies: %w[USD]).snapshot("USD")

    first = backtest
    second = backtest

    assert first.positive?
    assert_equal 0, second
    assert_equal first + 1, ForecastRun.where(provider: "internal").count
    assert_equal live.captured_at, live.reload.captured_at
  end

  test "too little history on a grid date is skipped, not stored" do
    seed(days: 3) # never enough for WINDOW + 1

    assert_equal 0, backtest
    assert_equal 0, ForecastRun.count
  end
end
