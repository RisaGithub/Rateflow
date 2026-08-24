require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  def store(provider, currency, captured_at, value)
    ForecastRun.store(provider: provider, currency: currency, captured_at: captured_at,
                      points: [ { horizon_date: Date.new(2026, 9, 1), value: BigDecimal(value), low: nil, high: nil } ])
  end

  test "returns every snapshot for the currency, oldest first, both providers" do
    store("apecon", "USD", Time.utc(2026, 8, 20), "80")
    store("apecon", "USD", Time.utc(2026, 8, 22), "81")
    store("internal", "USD", Time.utc(2026, 8, 22), "82")
    store("apecon", "EUR", Time.utc(2026, 8, 22), "95")

    get forecasts_path(currency: "USD")

    assert_response :success
    body = response.parsed_body
    assert_equal "USD", body["currency"]
    runs = body.dig("series", "apecon", "runs")
    assert_equal 2, runs.size
    assert_operator runs[0]["captured_at"], :<, runs[1]["captured_at"]
    assert_equal [ [ "2026-09-01", 82.0, nil, nil ] ], body.dig("series", "internal", "runs", 0, "points")
  end

  test "provider param narrows the payload; unknown values are dropped" do
    store("apecon", "USD", Time.utc(2026, 8, 22), "81")

    get forecasts_path(currency: "USD", provider: "apecon,bogus")

    assert_equal %w[apecon], response.parsed_body["series"].keys
  end
end
