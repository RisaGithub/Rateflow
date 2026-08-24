require "test_helper"

class ForecastsControllerTest < ActionDispatch::IntegrationTest
  def store(provider, currency, captured_at, value)
    ForecastRun.store(provider: provider, currency: currency, captured_at: captured_at,
                      points: [ { horizon_date: Date.new(2026, 9, 1), value: BigDecimal(value), low: nil, high: nil } ])
  end

  test "GET /forecasts renders the page with shared controls" do
    get forecasts_path

    assert_response :success
    assert_select "h1", text: "Прогнозы курса"
    assert_select "[data-controller=forecasts]"
    assert_select "[data-forecasts-target=accuracyGroup]", count: Rate::CURRENCIES.size
  end

  test "returns every snapshot for the currency, oldest first, both providers" do
    store("apecon", "USD", Time.utc(2026, 8, 20), "80")
    store("apecon", "USD", Time.utc(2026, 8, 22), "81")
    store("internal", "USD", Time.utc(2026, 8, 22), "82")
    store("apecon", "EUR", Time.utc(2026, 8, 22), "95")

    get forecasts_data_path(currency: "USD")

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

    get forecasts_data_path(currency: "USD", provider: "apecon,bogus")

    assert_equal %w[apecon], response.parsed_body["series"].keys
  end

  test "latest=1 returns only the newest snapshot per provider, without index" do
    store("apecon", "USD", Time.utc(2026, 8, 20), "80")
    store("apecon", "USD", Time.utc(2026, 8, 22), "81")

    get forecasts_data_path(currency: "USD", latest: "1")

    runs = response.parsed_body.dig("series", "apecon", "runs")
    assert_equal 1, runs.size
    assert_equal [ [ "2026-09-01", 81.0, nil, nil ] ], runs[0]["points"]
    assert_nil response.parsed_body.dig("series", "apecon", "index")
  end

  test "from param keeps only snapshots captured on that date or later" do
    store("apecon", "USD", Time.utc(2026, 5, 1), "78")
    store("apecon", "USD", Time.utc(2026, 8, 22), "81")

    get forecasts_data_path(currency: "USD", from: "2026-07-01")

    runs = response.parsed_body.dig("series", "apecon", "runs")
    assert_equal 1, runs.size
    assert_equal 1, response.parsed_body.dig("series", "apecon", "index").size
  end

  test "GET /forecasts/accuracy returns the groups for the requested period" do
    get forecasts_accuracy_path(from: "2026-07-01")

    assert_response :success
    assert_select "[data-forecasts-target=accuracyGroup]", count: Rate::CURRENCIES.size
    assert_select "section", count: 0 # groups only, no page shell
  end

  test "run param returns one exact snapshot" do
    run = store("apecon", "USD", Time.utc(2026, 8, 20), "80")
    store("apecon", "USD", Time.utc(2026, 8, 22), "81")

    get forecasts_data_path(run: run.id)

    body = response.parsed_body
    assert_equal run.id, body["id"]
    assert_equal "apecon", body["provider"]
    assert_equal [ [ "2026-09-01", 80.0, nil, nil ] ], body["points"]
  end
end
