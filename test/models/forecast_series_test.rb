require "test_helper"

class ForecastSeriesTest < ActiveSupport::TestCase
  def store_run(captured_at, value)
    run = ForecastRun.create!(provider: "internal", currency: "USD",
                              captured_at: captured_at, points_count: 1)
    ForecastPoint.insert_all!([ { forecast_run_id: run.id, horizon_date: captured_at.to_date + 7,
                                  value: value, low: nil, high: nil } ])
    run
  end

  test "runs are thinned to MAX_RUNS with the newest kept, index stays complete" do
    total = ForecastSeries::MAX_RUNS + 30
    newest = nil
    total.times { |i| newest = store_run(Time.utc(2024, 1, 1) + i.days, 80 + i * 0.01) }

    series = ForecastSeries.new(currency: "USD", providers: %w[internal]).as_json[:series]["internal"]

    assert_equal ForecastSeries::MAX_RUNS, series[:runs].size
    assert_equal newest.id, series[:runs].last[:id]
    assert_equal total, series[:index].size
    assert_equal newest.id, series[:index].last[:id]
    assert_equal (newest.captured_at.to_date + 7).iso8601, series[:index].last[:horizon_to]
  end

  test "from keeps only snapshots captured on that date or later, index included" do
    store_run(Time.utc(2026, 5, 1), 80)
    inside = store_run(Time.utc(2026, 8, 1), 81)

    series = ForecastSeries.new(currency: "USD", providers: %w[internal], from: Date.new(2026, 7, 1))
                           .as_json[:series]["internal"]

    assert_equal [ inside.id ], series[:runs].map { |r| r[:id] }
    assert_equal [ inside.id ], series[:index].map { |r| r[:id] }
  end

  test "latest_only keeps one run per provider and drops the index" do
    store_run(Time.utc(2026, 8, 1), 80)
    newest = store_run(Time.utc(2026, 8, 10), 81)

    series = ForecastSeries.new(currency: "USD", providers: %w[internal], latest_only: true)
                           .as_json[:series]["internal"]

    assert_equal [ newest.id ], series[:runs].map { |r| r[:id] }
    assert_nil series[:index]
  end

  test "run_as_json returns one full snapshot with sorted points" do
    run = ForecastRun.store(provider: "apecon", currency: "USD", captured_at: Time.utc(2026, 8, 10),
                            points: [ { horizon_date: Date.new(2026, 10, 1), value: BigDecimal("83"), low: BigDecimal("80"), high: BigDecimal("86") },
                                      { horizon_date: Date.new(2026, 9, 1), value: BigDecimal("82"), low: nil, high: nil } ])

    json = ForecastSeries.run_as_json(run)

    assert_equal "apecon", json[:provider]
    assert_equal [ [ "2026-09-01", 82.0, nil, nil ], [ "2026-10-01", 83.0, 80.0, 86.0 ] ], json[:points]
  end
end
