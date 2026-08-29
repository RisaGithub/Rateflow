require "test_helper"

class LogsPrunerTest < ActiveSupport::TestCase
  test "removes fetch logs older than the cutoff and keeps fresh ones" do
    old = FetchLog.create!(provider: "cbr", kind: "rates", ok: true, created_at: 91.days.ago)
    fresh = FetchLog.create!(provider: "cbr", kind: "rates", ok: true, created_at: 89.days.ago)

    removed = LogsPruner.new.call

    assert_equal 1, removed[:fetch_logs]
    assert_not FetchLog.exists?(old.id)
    assert FetchLog.exists?(fresh.id)
  end

  test "removes refresh checks older than a month and keeps fresh ones" do
    old = RefreshCheck.create!(kind: "forecast", origin: "task", outcome: "skipped", created_at: 31.days.ago)
    fresh = RefreshCheck.create!(kind: "forecast", origin: "task", outcome: "skipped", created_at: 29.days.ago)

    removed = LogsPruner.new.call

    assert_equal 1, removed[:refresh_checks]
    assert_not RefreshCheck.exists?(old.id)
    assert RefreshCheck.exists?(fresh.id)
  end

  test "removes stale internal snapshots with their points but never apecon ones" do
    points = [ { horizon_date: Date.new(2026, 9, 1), value: "80" } ]
    stale = ForecastRun.store(provider: "internal", currency: "USD", points: points,
                              captured_at: 366.days.ago)
    fresh = ForecastRun.store(provider: "internal", currency: "EUR", points: points,
                              captured_at: 300.days.ago)
    apecon = ForecastRun.store(provider: "apecon", currency: "USD", points: points,
                               captured_at: 3.years.ago)

    removed = LogsPruner.new.call

    assert_equal 1, removed[:internal_runs]
    assert_not ForecastRun.exists?(stale.id)
    assert_equal 0, ForecastPoint.where(forecast_run_id: stale.id).count
    assert ForecastRun.exists?(fresh.id)
    assert ForecastRun.exists?(apecon.id)
    assert_equal 1, apecon.points.count
  end
end
