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

    # Builds a one-table page out of rows, so a test can state exactly which
    # shape of markup it is about.
    def page(rows)
      body = rows.map { |cells| "<tr>" + cells.map { |c| "<td>#{c}</td>" }.join + "</tr>" }.join
      "<html><body><table><tr><th>Месяц</th><th>Мин-Макс</th><th>Курс</th><th>Всего,%</th></tr>#{body}</table></body></html>"
    end

    # Serves markup handed to it — for the year-header shapes below.
    class Shaped < Apecon
      def self.key = "apecon"

      def initialize(html) = @html = html

      private def get(_url) = [ @html, 200 ]
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

    # A datacenter IP gets a meta-refresh stub with status 200 instead of the
    # page. That is a blocked request, not broken markup, and the error has to
    # say so — otherwise the fetch log blames a redesign that never happened.
    test "a bot check is reported as a bot check, not as unrecognized markup" do
      challenge = Shaped.new(
        '<html><head><meta http-equiv="refresh" content="0;/.well-known/sgcaptcha/?r=%2F"></head></html>'
      )

      error = assert_raises(Providers::Error) { challenge.fetch_forecast("USD") }

      assert_match(/bot check/, error.message)
      assert_no_match(/not recognized/, error.message)
    end

    test "unknown currency raises Providers::Error" do
      assert_raises(Providers::Error) { Stubbed.new.fetch_forecast("JPY") }
    end

    # apecon.ru writes its year headers as a single spanning cell today. If that
    # cell is ever padded out to the table's width instead, the row is still a
    # year header — only one cell of it carries anything.
    test "a year header padded with empty cells still sets the year" do
      html = page([ [ "2026", "", "", "" ],
                    [ "Авг", "79.12-85.44", "81.18", "2.5%" ],
                    [ "Сен", "78.49-89.40", "79.69", "0.6%" ] ])

      points = Shaped.new(html).fetch_forecast("USD").points

      assert_equal [ Date.new(2026, 8, 1), Date.new(2026, 9, 1) ], points.map { |p| p[:horizon_date] }
      assert_equal BigDecimal("81.18"), points.first[:value]
    end

    # With no year headers at all the table's own order carries the year:
    # months only ever run forward, so one that does not advance starts the
    # next year. Without this the whole table used to parse into nothing.
    test "with no year headers the rows are dated by their order" do
      year = Date.current.year
      html = page([ [ "Ноя", "80.23-83.88", "82.64", "4.3%" ],
                    [ "Дек", "78.96-82.64", "80.16", "1.2%" ],
                    [ "Янв", "76.59-80.16", "77.76", "-1.9%" ],
                    [ "Фев", "77.76-81.29", "80.09", "1.1%" ] ])

      points = Shaped.new(html).fetch_forecast("USD").points

      assert_equal [ Date.new(year, 11, 1), Date.new(year, 12, 1),
                     Date.new(year + 1, 1, 1), Date.new(year + 1, 2, 1) ],
                   points.map { |p| p[:horizon_date] }
    end

    # "Not recognized" on its own cannot tell a redesign apart from a stub page
    # served to our IP, so the message carries what the page actually was.
    test "a parse failure reports the shape of the page it saw" do
      error = assert_raises(Providers::Error) { Broken.new.fetch_forecast("USD") }

      assert_match(/0 tables/, error.message)
      assert_match(/0 month rows/, error.message)
      # A page with no tables is quoted, so a stub served to our IP is readable
      # straight from the fetch log.
      assert_match(/Совсем другая разметка/, error.message)
    end
  end
end
