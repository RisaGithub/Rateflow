require "test_helper"

class DashboardControllerTest < ActionDispatch::IntegrationTest
  def rate(provider, value, on_date: Date.new(2026, 8, 26))
    Rate.create!(provider: provider, currency: "USD", on_date: on_date, value: value)
  end

  test "GET / renders the shell without embedding any data" do
    rate("cbr", "79.24", on_date: Date.new(2026, 8, 25))
    rate("cbr", "79.42")

    get root_path

    assert_response :success
    assert_select "[data-controller=dashboard]"
    # The whole point of the shell: the page carries no rates, only skeletons.
    assert_no_match "79.42", response.body
    assert_select "[data-dashboard-initial-value]", count: 0
    assert_select "[data-dashboard-rates-value]", count: 0
    assert_select ".ccard--skel", count: Rate::CURRENCIES.size
  end

  test "GET /dashboard/data returns cards, rates and the empty flag" do
    rate("cbr", "79.24", on_date: Date.new(2026, 8, 25))
    rate("cbr", "79.42")

    get dashboard_data_path

    assert_response :success
    body = response.parsed_body
    assert_equal false, body["empty"]
    assert_equal Rate::CURRENCIES, body["cards"].map { |c| c["code"] }

    usd = body["cards"].first
    assert_equal "Доллар США", usd["name"]
    assert_equal 79.42, usd["value"]
    assert_equal "cbr", usd["provider"]
    assert_equal "2026-08-26", usd["on_date"]
    assert_in_delta 0.18, usd["delta"], 0.0001
    assert_equal [ 79.24, 79.42 ], usd["spark"]

    assert_equal({ "value" => 79.42, "provider" => "cbr", "date" => "2026-08-26" }, body.dig("rates", "USD"))
  end

  test "GET /dashboard/data reports an empty database" do
    get dashboard_data_path

    assert_response :success
    assert_equal true, response.parsed_body["empty"]
    assert_equal [], response.parsed_body["rates"].keys
    assert_nil response.parsed_body["cards"].first["value"]
  end
end
