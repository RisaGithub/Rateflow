require "test_helper"

class RatesFetcherTest < ActiveSupport::TestCase
  # Stand-in for a provider: returns canned records or raises.
  class FakeProvider
    attr_reader :key

    def initialize(key, records: [], error: nil)
      @key = key
      @records = records
      @error = error
    end

    def fetch(_currencies, from:, to:)
      raise @error if @error

      Providers::Result.new(records: @records, http_status: 200)
    end
  end

  def record(value = "70.5")
    { currency: "USD", on_date: Date.new(2026, 6, 15), value: BigDecimal(value) }
  end

  test "one provider failing does not stop the other two" do
    providers = [
      FakeProvider.new("cbr", error: Providers::Error.new("HTTP 500", http_status: 500)),
      FakeProvider.new("erapi", records: [ record("71.1") ]),
      FakeProvider.new("currencyapi", records: [ record("71.2") ])
    ]

    written = RatesFetcher.new(providers: providers).call

    assert_equal 2, written
    assert_equal %w[currencyapi erapi], Rate.distinct.pluck(:provider).sort
  end

  test "every attempt lands in FetchLog, failures included" do
    providers = [
      FakeProvider.new("cbr", error: Providers::Error.new("HTTP 500", http_status: 500)),
      FakeProvider.new("erapi", records: [ record ]),
      FakeProvider.new("currencyapi", records: [ record ])
    ]

    RatesFetcher.new(providers: providers).call

    logs = FetchLog.order(:id).last(3)
    assert_equal %w[cbr erapi currencyapi], logs.map(&:provider)
    assert_equal [ false, true, true ], logs.map(&:ok)
    assert_equal "HTTP 500", logs.first.error_message
  end

  test "the default provider list leaves apecon out — its quote rides with the forecast fetch" do
    providers = RatesFetcher.new.instance_variable_get(:@providers)

    assert_equal %w[cbr erapi currencyapi], providers.map(&:key)
  end

  test "re-running writes no duplicate rows" do
    providers = [ FakeProvider.new("cbr", records: [ record ]) ]

    2.times { RatesFetcher.new(providers: providers).call }

    assert_equal 1, Rate.where(provider: "cbr", currency: "USD", on_date: Date.new(2026, 6, 15)).count
  end
end
