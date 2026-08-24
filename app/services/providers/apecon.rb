module Providers
  # АПЭКОН (apecon.ru) — агентство прогнозирования экономики. Plain HTML pages,
  # one per currency, each carrying today's quote and a monthly forecast table.
  #
  # Parsing is structural on purpose: we look for a table row shaped like the
  # data («Ммм [ГГГГ]» + «мин-макс»), never for CSS classes — the markup of
  # someone else's site can change at any moment, and when it does the parser
  # raises Providers::Error, which lands in FetchLog without sinking the app.
  class Apecon < Base
    PAGES = {
      "USD" => "https://apecon.ru/",
      "EUR" => "https://apecon.ru/kurs-evro-prognoz-na-zavtra-nedelyu-mesyats-yanvar-fevral-mart-aprel-maj-iyun-iyul-avgust-sentyabr-oktyabr-noyabr-dekabr",
      "CNY" => "https://apecon.ru/kurs-yuanya-prognoz-na-zavtra-nedelyu-mesyats-gody",
      "GBP" => "https://apecon.ru/kurs-funta-prognoz-na-zavtra-nedelyu-mesyats-gody"
    }.freeze

    # robots.txt on apecon.ru declares "Crawl-delay: 10" — never more than one
    # request per 10 seconds, enforced process-wide across provider instances.
    CRAWL_DELAY = 10

    MONTHS = %w[янв фев мар апр май июн июл авг сен окт ноя дек].freeze
    # «Авг», «Сент», «Авг 2026» — a short Russian month name, optionally with a year.
    MONTH_RE = /\A(#{MONTHS.join("|")})[а-яё]*\.?(?:\s+(\d{4}))?\z/i
    # «79.12-85.44» or «106-117» — the min-max range column.
    RANGE_RE = /\A(\d+(?:[.,]\d+)?)\s*[-–—]\s*(\d+(?:[.,]\d+)?)\z/
    NUMBER_RE = /\A\d+(?:[.,]\d+)?\z/
    PERCENT_RE = /\A[+−-]?\d+(?:[.,]\d+)?\s*%\z/

    CRAWL_LOCK = Mutex.new

    class << self
      # Sleeps out the remainder of the crawl delay since the previous request.
      def respect_crawl_delay
        CRAWL_LOCK.synchronize do
          elapsed = @last_request_at && monotonic - @last_request_at
          sleep(CRAWL_DELAY - elapsed) if elapsed && elapsed < CRAWL_DELAY
          yield
        ensure
          @last_request_at = monotonic
        end
      end

      private def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    # Today's quote for each currency. One failing page does not sink the
    # rest — same contract as Cbr#fetch. from/to accepted for interface parity.
    def fetch(currencies, from: nil, to: nil)
      records, status, error = [], nil, nil
      currencies.each do |currency|
        body, status = page(currency)
        records << parse_quote(body, currency)
      rescue Error => e
        error = e
      end
      raise error if records.empty? && error

      Result.new(records: records, http_status: status)
    end

    private

    def page(currency)
      url = PAGES.fetch(currency) { raise Error, "Unknown currency #{currency}" }
      get(url)
    end

    # Base#get plus the mandatory pause between any two requests to the site.
    def get(url)
      self.class.respect_crawl_delay { super }
    end

    # The quote sits in a small table right under the «ДД.ММ.ГГГГ. Курс …
    # сегодня» headline: a row with a bare number followed by a percent cell.
    # The first such row in document order is the quote.
    def parse_quote(body, currency)
      doc = parse_html(body)
      date = doc.text[/(\d{2}\.\d{2}\.\d{4})\.\s*Курс/, 1] or raise Error, "Quote date not found"

      value = nil
      each_row(doc) do |cells|
        i = cells.index { |c| c.match?(NUMBER_RE) }
        value = decimal(cells[i]) if i && cells[i + 1]&.match?(PERCENT_RE)
        break if value
      end
      raise Error, "Quote not found" unless value&.positive?

      { currency: currency, on_date: Date.strptime(date, "%d.%m.%Y"), value: value }
    rescue Date::Error => e
      raise Error, "Unexpected apecon page: #{e.message}"
    end

    def parse_html(body)
      Nokogiri::HTML(body.to_s.force_encoding("utf-8"))
    end

    # Yields every table row as an array of stripped cell texts, in document order.
    def each_row(doc)
      doc.css("table tr").each do |tr|
        yield tr.css("th, td").map { |cell| cell.text.gsub(/[[:space:]]+/, " ").strip }
      end
    end

    # "81.18" / "81,18" -> BigDecimal
    def decimal(str) = BigDecimal(str.strip.tr(",", "."))
  end
end
