require "test_helper"

class ForecastAccuracyTest < ActiveSupport::TestCase
  def fact(date, value, currency: "USD")
    Rate.create!(provider: "cbr", currency: currency, on_date: date, value: value)
  end

  def snapshot(captured_on, points, provider: "apecon", currency: "USD")
    ForecastRun.store(provider: provider, currency: currency,
                      points: points, captured_at: captured_on.to_time.utc)
  end

  test "MAE and MAPE over matured points, bucketed by lead time" do
    fact(Date.new(2026, 6, 5), "100")
    fact(Date.new(2026, 6, 10), "100")
    snapshot(Date.new(2026, 6, 1), [
      { horizon_date: Date.new(2026, 6, 5), value: BigDecimal("95"), low: nil, high: nil },   # lead 4, err 5
      { horizon_date: Date.new(2026, 6, 10), value: BigDecimal("90"), low: nil, high: nil }   # lead 9, err 10
    ])

    report = ForecastAccuracy.new.report("apecon")

    assert_equal 2, report.samples
    assert_in_delta 7.5, report.mae, 0.0001
    assert_in_delta 7.5, report.mape, 0.0001
    buckets = report.buckets.to_h
    assert_equal({ samples: 1, mae: 5.0, mape: 5.0 }, buckets["до 7 дней"])
    assert_equal({ samples: 1, mae: 10.0, mape: 10.0 }, buckets["8–30 дней"])
    assert_equal({ samples: 0, mae: nil, mape: nil }, buckets["30+ дней"])
  end

  test "hindsight, future and fact-less points are excluded" do
    fact(Date.new(2026, 5, 1), "100")
    snapshot(Date.new(2026, 5, 20), [
      { horizon_date: Date.new(2026, 5, 1), value: BigDecimal("95"), low: nil, high: nil },   # «прогноз» задним числом
      { horizon_date: Date.new(2026, 6, 1), value: BigDecimal("95"), low: nil, high: nil },   # нет факта ЦБ на эту дату
      { horizon_date: Date.new(2099, 1, 1), value: BigDecimal("95"), low: nil, high: nil }    # ещё не наступила
    ])

    report = ForecastAccuracy.new.report("apecon")

    assert_equal 0, report.samples
    assert_nil report.mae
  end

  test "currency option narrows scoring to that currency alone" do
    fact(Date.new(2026, 6, 10), "100")
    fact(Date.new(2026, 6, 10), "11", currency: "CNY")
    snapshot(Date.new(2026, 6, 1), [ { horizon_date: Date.new(2026, 6, 10), value: BigDecimal("95"), low: nil, high: nil } ])
    snapshot(Date.new(2026, 6, 1), [ { horizon_date: Date.new(2026, 6, 10), value: BigDecimal("10"), low: nil, high: nil } ],
             currency: "CNY")

    report = ForecastAccuracy.new(currency: "USD").report("apecon")

    assert_equal 1, report.samples
    assert_in_delta 5.0, report.mae, 0.0001
    assert_equal 2, ForecastAccuracy.new.report("apecon").samples # без фильтра — обе валюты
  end

  test "from option keeps only points that matured inside the period" do
    fact(Date.new(2026, 6, 5), "100")
    fact(Date.new(2026, 6, 10), "100")
    snapshot(Date.new(2026, 6, 1), [
      { horizon_date: Date.new(2026, 6, 5), value: BigDecimal("95"), low: nil, high: nil },
      { horizon_date: Date.new(2026, 6, 10), value: BigDecimal("90"), low: nil, high: nil }
    ])

    report = ForecastAccuracy.new(from: Date.new(2026, 6, 8)).report("apecon")

    assert_equal 1, report.samples
    assert_in_delta 10.0, report.mae, 0.0001
  end

  test "providers are scored separately" do
    fact(Date.new(2026, 6, 10), "100")
    snapshot(Date.new(2026, 6, 1),
             [ { horizon_date: Date.new(2026, 6, 10), value: BigDecimal("98"), low: nil, high: nil },
               { horizon_date: Date.new(2026, 6, 11), value: BigDecimal("98"), low: nil, high: nil } ])

    reports = ForecastAccuracy.new.reports.index_by(&:provider)

    assert_equal 1, reports["apecon"].samples
    assert_equal 0, reports["internal"].samples
  end
end
