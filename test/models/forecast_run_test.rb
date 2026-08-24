require "test_helper"

class ForecastRunTest < ActiveSupport::TestCase
  def points(value: "80.5")
    [
      { horizon_date: Date.new(2026, 9, 1), value: BigDecimal(value), low: BigDecimal("78"), high: BigDecimal("83") },
      { horizon_date: Date.new(2026, 10, 1), value: BigDecimal("81.2"), low: nil, high: nil }
    ]
  end

  test "identical snapshot does not create a second version, only refreshes captured_at" do
    first = ForecastRun.store(provider: "apecon", currency: "USD", points: points,
                              captured_at: Time.utc(2026, 8, 20, 12))
    second = ForecastRun.store(provider: "apecon", currency: "USD", points: points,
                               captured_at: Time.utc(2026, 8, 21, 12))

    assert_equal first.id, second.id
    assert_equal 1, ForecastRun.count
    assert_equal Time.utc(2026, 8, 21, 12), second.reload.captured_at
    assert_equal 2, second.points.count
  end

  test "changed snapshot becomes a new version and keeps the old one" do
    ForecastRun.store(provider: "apecon", currency: "USD", points: points)
    ForecastRun.store(provider: "apecon", currency: "USD", points: points(value: "99.9"))

    assert_equal 2, ForecastRun.count
    assert_equal 4, ForecastPoint.count
  end

  test "dedup is scoped to provider and currency" do
    ForecastRun.store(provider: "apecon", currency: "USD", points: points)
    ForecastRun.store(provider: "internal", currency: "USD", points: points)
    ForecastRun.store(provider: "apecon", currency: "EUR", points: points)

    assert_equal 3, ForecastRun.count
  end

  test "empty snapshot is rejected" do
    assert_raises(ArgumentError) { ForecastRun.store(provider: "apecon", currency: "USD", points: []) }
  end
end
