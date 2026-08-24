require "test_helper"

class ForecastsFetcherTest < ActiveSupport::TestCase
  # Stand-in for the АПЭКОН provider: canned points or a canned failure.
  class FakeProvider
    attr_reader :fetched

    def initialize(error: nil)
      @error = error
      @fetched = []
    end

    def key = "apecon"

    def fetch_forecast(currency)
      @fetched << currency
      raise @error if @error

      Providers::Apecon::ForecastResult.new(
        points: [
          { horizon_date: Date.new(2026, 9, 1), value: BigDecimal("80"), low: BigDecimal("78"), high: BigDecimal("83") },
          { horizon_date: Date.new(2026, 10, 1), value: BigDecimal("81"), low: BigDecimal("79"), high: BigDecimal("84") }
        ],
        source_url: "https://apecon.ru/", http_status: 200
      )
    end
  end

  def store(currency, captured_at)
    ForecastRun.store(provider: "apecon", currency: currency, captured_at: captured_at,
                      points: [ { horizon_date: Date.new(2026, 9, 1), value: BigDecimal(rand(70..90).to_s), low: nil, high: nil } ])
  end

  test "updates exactly one currency per call — the stalest one" do
    store("USD", 3.days.ago)
    store("EUR", 5.days.ago)
    provider = FakeProvider.new

    result = ForecastsFetcher.new(provider: provider, currencies: %w[USD EUR]).call

    assert_equal "ok", result[:status]
    assert_equal %w[EUR], provider.fetched
    assert FetchLog.for_kind("forecast").succeeded.exists?
  end

  test "a currency without any snapshot wins over every dated one" do
    store("USD", 30.days.ago)
    provider = FakeProvider.new

    ForecastsFetcher.new(provider: provider, currencies: %w[USD EUR]).call

    assert_equal %w[EUR], provider.fetched
  end

  test "everything fresher than a day means no request at all" do
    store("USD", 2.hours.ago)
    store("EUR", 3.hours.ago)
    provider = FakeProvider.new

    result = ForecastsFetcher.new(provider: provider, currencies: %w[USD EUR]).call

    assert_equal "fresh", result[:status]
    assert_empty provider.fetched
  end

  test "provider failure lands in FetchLog and is reported, not raised" do
    provider = FakeProvider.new(error: Providers::Error.new("HTTP 500", http_status: 500))

    result = ForecastsFetcher.new(provider: provider, currencies: %w[USD]).call

    assert_equal "error", result[:status]
    log = FetchLog.for_kind("forecast").recent.first
    assert_not log.ok
    assert_equal "HTTP 500", log.error_message
  end
end
