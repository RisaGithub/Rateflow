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

  def record(value = "70.5", on_date: Date.new(2026, 6, 15))
    { currency: "USD", on_date: on_date, value: BigDecimal(value) }
  end

  def eur(value, on_date: Date.new(2026, 6, 15))
    { currency: "EUR", on_date: on_date, value: BigDecimal(value) }
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

  # The providers resend two weeks of history every run. Rewriting rows that
  # did not move would bump updated_at — the cache key behind /series — and
  # re-snapshot the internal forecast, both for nothing.
  test "a repeat run with identical data writes nothing and leaves updated_at alone" do
    providers = [ FakeProvider.new("cbr", records: [ record ]) ]
    RatesFetcher.new(providers: providers).call
    before = Rate.maximum(:updated_at)

    travel 1.hour do
      assert_equal 0, RatesFetcher.new(providers: providers).call
    end

    assert_equal before, Rate.maximum(:updated_at)
  end

  test "a changed value is written, an unchanged one next to it is not" do
    RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: [ record("70.5"), eur("95.0") ]) ]).call

    written = RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: [ record("70.6"), eur("95.0") ]) ]).call

    assert_equal 1, written
    assert_equal BigDecimal("70.6"), Rate.latest_for("USD", "cbr").value
  end

  test "a new date is written" do
    RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: [ record ]) ]).call

    fresh = record.merge(on_date: Date.new(2026, 6, 16))
    written = RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: [ record, fresh ]) ]).call

    assert_equal 1, written
    assert_equal 2, Rate.where(provider: "cbr", currency: "USD").count
  end

  # Postgres keeps four decimals; comparing at any finer precision would call
  # the same number "changed" on every single run.
  test "extra decimals beyond the column's scale do not count as a change" do
    RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: [ record("70.5") ]) ]).call

    written = RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: [ record("70.500004") ]) ]).call

    assert_equal 0, written
  end

  test "a run that writes nothing does not recompute the internal forecast" do
    records = 10.times.map { |i| record("70.5", on_date: Date.new(2026, 6, 5) + i) }
    RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: records) ]).call
    assert_equal 1, ForecastRun.where(provider: "internal", currency: "USD").count

    ForecastRun.for("USD", "internal").delete_all
    RatesFetcher.new(providers: [ FakeProvider.new("cbr", records: records) ]).call

    assert_equal 0, ForecastRun.where(provider: "internal").count
  end

  test "rows received counts everything the providers sent, written only the changes" do
    providers = [ FakeProvider.new("cbr", records: [ record, eur("95.0") ]) ]
    RatesFetcher.new(providers: providers).call

    fetcher = RatesFetcher.new(providers: providers)

    assert_equal 0, fetcher.call
    assert_equal 2, fetcher.received
  end
end
