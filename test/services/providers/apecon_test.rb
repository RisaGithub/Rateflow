require "test_helper"

module Providers
  class ApeconTest < ActiveSupport::TestCase
    FIXTURE = File.expand_path("../../fixtures/files/apecon_usd.html", __dir__)

    # Serves the saved apecon.ru page instead of hitting the site (and thereby
    # also skips the crawl-delay pause built into the real #get).
    class Stubbed < Apecon
      def self.key = "apecon"

      def requests = @requests.to_i

      private def get(_url)
        @requests = requests + 1
        [ File.binread(FIXTURE), 200 ]
      end
    end

    # A page whose markup no longer holds the expected tables.
    class Broken < Apecon
      def self.key = "apecon"

      private def get(_url) = [ "<html><body><p>Совсем другая разметка</p></body></html>", 200 ]
    end

    test "parses today's quote with the page's own date" do
      result = Stubbed.new.fetch(%w[USD])

      assert_equal 200, result.http_status
      assert_equal [ { currency: "USD", on_date: Date.new(2026, 8, 24), value: BigDecimal("83.29") } ],
                   result.records
    end

    test "parses the monthly forecast: russian months, min-max range, fractions" do
      result = Stubbed.new.fetch_forecast("USD")

      assert_equal "https://apecon.ru/", result.source_url
      assert_equal 50, result.points.size

      first = result.points.first
      assert_equal Date.new(2026, 8, 1), first[:horizon_date] # «Авг» под строкой «2026»
      assert_equal BigDecimal("81.18"), first[:value]
      assert_equal BigDecimal("79.12"), first[:low]
      assert_equal BigDecimal("85.44"), first[:high]

      january = result.points.find { |p| p[:horizon_date] == Date.new(2027, 1, 1) }
      assert_equal BigDecimal("77.76"), january[:value] # год из заголовочной строки «2027»

      # Second table continues 2028 («2028 продолжение») — no month is lost.
      assert_equal Date.new(2030, 9, 1), result.points.last[:horizon_date]
      assert_equal result.points.size, result.points.map { |p| p[:horizon_date] }.uniq.size
    end

    test "forecast and quote share a single page load per instance" do
      provider = Stubbed.new

      forecast = provider.fetch_forecast("USD")
      quote = provider.fetch(%w[USD])

      assert_equal 1, provider.requests # the second call reads the cached page
      assert_equal 50, forecast.points.size
      assert_equal BigDecimal("83.29"), quote.records.first[:value]
    end

    test "unrecognized markup raises Providers::Error, not a bare exception" do
      assert_raises(Providers::Error) { Broken.new.fetch_forecast("USD") }
      assert_raises(Providers::Error) { Broken.new.fetch(%w[USD]) }
    end

    test "unknown currency raises Providers::Error" do
      assert_raises(Providers::Error) { Stubbed.new.fetch_forecast("JPY") }
    end
  end
end
