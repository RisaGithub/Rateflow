require "test_helper"

class ForecastsFetcherTest < ActiveSupport::TestCase
  # Stand-in for the АПЭКОН provider: canned points or a canned failure.
  # Like the real one, it serves the quote from the already-loaded page.
  class FakeProvider
    attr_reader :fetched

    def initialize(error: nil, quote_error: nil)
      @error = error
      @quote_error = quote_error
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

    def fetch(currencies, from: nil, to: nil)
      raise @quote_error if @quote_error

      records = currencies.map { |c| { currency: c, on_date: Date.current, value: BigDecimal("82.5") } }
      Providers::Result.new(records: records, http_status: 200)
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

  test "the same call stores the page's quote into rates under apecon" do
    result = ForecastsFetcher.new(provider: FakeProvider.new, currencies: %w[USD]).call

    assert_equal 1, result[:quote_rows]
    rate = Rate.find_by(provider: "apecon", currency: "USD", on_date: Date.current)
    assert_equal BigDecimal("82.5"), rate.value
  end

  test "a page without a recognizable quote still counts as a forecast success" do
    provider = FakeProvider.new(quote_error: Providers::Error.new("Quote not found"))

    result = ForecastsFetcher.new(provider: provider, currencies: %w[USD]).call

    assert_equal "ok", result[:status]
    assert_equal 0, result[:quote_rows]
    assert_not Rate.where(provider: "apecon").exists?
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

  test "fetch_all walks the currencies in order, pausing between page loads" do
    provider = FakeProvider.new
    slept = []

    results = ForecastsFetcher.fetch_all(currencies: %w[USD EUR], provider: provider,
                                         sleeper: ->(s) { slept << s })

    assert_equal %w[USD EUR], provider.fetched
    assert_equal [ ForecastsFetcher::CRAWL_DELAY ], slept
    assert_equal %w[ok ok], results.map { |r| r[:status] }
    assert_equal %w[USD EUR], results.map { |r| r[:currency] }
    assert_equal 2, Rate.where(provider: "apecon").count
  end

  test "fetch_all never pauses after a fresh currency — no request was made" do
    store("USD", 2.hours.ago)
    provider = FakeProvider.new
    slept = []

    results = ForecastsFetcher.fetch_all(currencies: %w[USD EUR], provider: provider,
                                         sleeper: ->(s) { slept << s })

    assert_equal %w[EUR], provider.fetched
    assert_empty slept
    assert_equal [ %w[USD fresh], %w[EUR ok] ], results.map { |r| [ r[:currency], r[:status] ] }
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
