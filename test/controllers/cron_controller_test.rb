require "test_helper"

class CronControllerTest < ActionDispatch::IntegrationTest
  # A fetcher that must never be reached — proves "skipped" stays off the network.
  class ExplodingFetcher
    def call = raise("network must not be touched")
  end

  SilentFetcher = Struct.new(:result) do
    def call = result
  end

  setup do
    @old_token = ENV["CRON_TOKEN"]
    ENV["CRON_TOKEN"] = "s3cret"
    CronController::RATE_LIMIT_STORE.clear
  end

  teardown { ENV["CRON_TOKEN"] = @old_token }

  # Makes klass.new return `fake` for the duration of the block — the request
  # must never construct a real fetcher (and thereby hit the network).
  def stubbing_new(klass, fake)
    klass.define_singleton_method(:new) { |*, **| fake }
    yield
  ensure
    klass.singleton_class.remove_method(:new)
  end

  test "no CRON_TOKEN in the environment shuts the endpoint with 503" do
    ENV["CRON_TOKEN"] = nil
    get cron_refresh_path(token: "anything")
    assert_response :service_unavailable
  end

  test "missing or wrong token gets a bare 401" do
    get cron_refresh_path
    assert_response :unauthorized

    get cron_refresh_path(token: "wrong")
    assert_response :unauthorized
  end

  test "valid token refreshes rates and reports JSON" do
    stubbing_new(RatesFetcher, SilentFetcher.new(7)) do
      get cron_refresh_path(token: "s3cret")
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal 7, body["rows_written"]
    assert body.key?("duration_ms")
  end

  test "a refresh that ran under 10 minutes ago is skipped without touching the network" do
    FetchLog.create!(provider: "cbr", kind: "rates", ok: true)

    stubbing_new(RatesFetcher, ExplodingFetcher.new) do
      get cron_refresh_path(token: "s3cret")
    end

    assert_response :success
    assert_equal "skipped", response.parsed_body["status"]
  end

  test "forecasts endpoint updates one currency and recomputes the internal forecast" do
    apecon = { status: "ok", currency: "USD", points: 50 }
    stubbing_new(ForecastsFetcher, SilentFetcher.new(apecon)) do
      stubbing_new(InternalForecast, SilentFetcher.new(4)) do
        get cron_forecasts_path(token: "s3cret")
      end
    end

    assert_response :success
    body = response.parsed_body
    assert_equal "ok", body["status"]
    assert_equal "USD", body.dig("apecon", "currency")
    assert_equal 4, body["internal_snapshots"]
  end

  test "more than 20 requests per minute from one address get 429" do
    20.times { get cron_refresh_path(token: "wrong") }
    assert_response :unauthorized

    get cron_refresh_path(token: "wrong")
    assert_response :too_many_requests
    assert_match "Too many requests", response.parsed_body["error"]
  end

  test "forecasts endpoint is throttled by its own kind of log" do
    FetchLog.create!(provider: "apecon", kind: "forecast", ok: true)

    stubbing_new(ForecastsFetcher, ExplodingFetcher.new) do
      get cron_forecasts_path(token: "s3cret")
    end

    assert_response :success
    assert_equal "skipped", response.parsed_body["status"]
  end
end
