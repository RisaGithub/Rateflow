require "test_helper"

# The very first thing a visitor sees right after a deploy is an empty
# database — every public page must render calmly, not break.
class EmptyDatabaseTest < ActionDispatch::IntegrationTest
  test "every public page renders on a completely empty database" do
    [ root_path, forecasts_path, sources_path, about_path ].each do |path|
      get path
      assert_response :success, "#{path} failed on an empty database"
    end
  end

  # The dashboard and the forecasts page carry the notice in their markup but
  # keep it hidden: it is the JSON payload that decides whether to raise it,
  # so neither page has to ask the database anything to render.
  test "dashboard and forecasts ship the first-run notice hidden" do
    [ root_path, forecasts_path ].each do |path|
      get path
      assert_select "[hidden] .empty-notice", 1, "#{path} misses the hidden first-run notice"
    end
  end

  test "sources leads with a first-run notice" do
    get sources_path
    assert_match "Данных пока нет", response.body
  end

  test "the empty flag in the JSON payloads flips once data arrives" do
    get dashboard_data_path
    assert_equal true, response.parsed_body["empty"]

    get forecasts_data_path(currency: "USD")
    assert_equal true, response.parsed_body["empty"]

    Rate.create!(provider: "cbr", currency: "USD", on_date: Date.new(2026, 8, 1), value: "80")
    FetchLog.create!(provider: "cbr", kind: "rates", ok: true)
    ForecastRun.store(provider: "apecon", currency: "USD",
                      points: [ { horizon_date: Date.new(2026, 9, 1), value: "80" } ])

    get dashboard_data_path
    assert_equal false, response.parsed_body["empty"]

    get forecasts_data_path(currency: "USD")
    assert_equal false, response.parsed_body["empty"]

    get sources_path
    assert_no_match "Данных пока нет", response.body
  end

  test "data endpoints answer valid empty JSON on an empty database" do
    get series_path(currency: "USD")
    assert_response :success

    get forecasts_data_path(currency: "USD")
    assert_response :success
    assert_equal [], response.parsed_body.dig("series", "apecon", "runs")

    get forecasts_accuracy_path
    assert_response :success
  end
end
