require "test_helper"

class InternalForecastTest < ActiveSupport::TestCase
  def seed(values, from: Date.new(2026, 8, 1))
    values.each_with_index do |value, i|
      Rate.create!(provider: "cbr", currency: "USD", on_date: from + i, value: value)
    end
  end

  test "snapshots a rolling-mean continuation with daily horizon dates" do
    seed([ 100, 100, 100, 100, 100, 100, 100, 100 ]) # last date: 2026-08-08

    run = InternalForecast.new(currencies: %w[USD]).snapshot("USD")

    assert_equal "internal", run.provider
    assert_equal 7, run.points_count
    points = run.points.order(:horizon_date)
    assert_equal Date.new(2026, 8, 9), points.first.horizon_date
    assert_equal Date.new(2026, 8, 15), points.last.horizon_date
    assert points.all? { |p| p.value == 100 } # mean of constant series stays constant
    assert points.all? { |p| p.low.nil? && p.high.nil? }
  end

  test "first projected point is the mean of the last seven values" do
    seed([ 1, 1, 70, 70, 70, 70, 70, 70, 70 ]) # last seven values are all 70

    run = InternalForecast.new(currencies: %w[USD]).snapshot("USD")

    assert_equal BigDecimal("70"), run.points.order(:horizon_date).first.value
  end

  test "too little history produces no snapshot" do
    seed([ 100, 100, 100 ])

    assert_nil InternalForecast.new(currencies: %w[USD]).snapshot("USD")
    assert_equal 0, ForecastRun.count
  end

  test "unchanged data does not multiply versions" do
    seed([ 100, 101, 102, 103, 104, 105, 106, 107 ])

    2.times { InternalForecast.new(currencies: %w[USD]).call }

    assert_equal 1, ForecastRun.where(provider: "internal", currency: "USD").count
  end
end
