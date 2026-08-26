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

  test "dashboard, forecasts and sources lead with a first-run notice" do
    [ root_path, forecasts_path, sources_path ].each do |path|
      get path
      assert_match "Данных пока нет", response.body, "#{path} misses the first-run notice"
    end
  end

  test "the first-run notice disappears once data arrives" do
    Rate.create!(provider: "cbr", currency: "USD", on_date: Date.new(2026, 8, 1), value: "80")
    FetchLog.create!(provider: "cbr", kind: "rates", ok: true)
    ForecastRun.store(provider: "apecon", currency: "USD",
                      points: [ { horizon_date: Date.new(2026, 9, 1), value: "80" } ])

    [ root_path, forecasts_path, sources_path ].each do |path|
      get path
      assert_no_match "Данных пока нет", response.body, "#{path} still shows the first-run notice"
    end
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
