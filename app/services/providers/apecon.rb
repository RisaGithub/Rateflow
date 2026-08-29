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

    # Result of one fetch_forecast call.
    ForecastResult = Struct.new(:points, :source_url, :http_status, keyword_init: true)

    CRAWL_LOCK = Mutex.new

    # apecon.ru sits behind an sgcaptcha bot check that challenges by IP: a
    # datacenter address gets a meta-refresh stub instead of the page, with a
    # 200 status. That is the site saying it does not want automated requests
    # from servers, so we report it plainly and do not try to get around it.
    CHALLENGE_RE = /sgcaptcha|\/\.well-known\/captcha/i

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
        page = fetch_page(currency)
        status = page[:http_status]
        records << demand(page[:quote], page)
      rescue Error => e
        error = e
      end
      raise error if records.empty? && error

      Result.new(records: records, http_status: status)
    end

    # Monthly forecast for one currency: an array of
    # {horizon_date:, value:, low:, high:} points, horizon_date being the first
    # day of the forecast month. Fewer than two recognized rows means the
    # markup changed — that is a provider error, not a partial success.
    def fetch_forecast(currency)
      page = fetch_page(currency)
      points = demand(page[:forecast], page)
      if points.size < 2
        raise Error.new("Monthly forecast table not recognized (#{page[:shape]})",
                        http_status: page[:http_status])
      end

      ForecastResult.new(points: points, source_url: page[:url], http_status: page[:http_status])
    end

    private

    # The quote and the forecast live on the same page, so one instance loads
    # each currency's HTML exactly once (one crawl-delay pause) and both fetch
    # and fetch_forecast read from the cached parse. Each half is parsed
    # independently: a page with a broken quote can still serve its forecast.
    # Failed page loads are not cached — a retry gets a fresh request.
    def fetch_page(currency)
      (@pages ||= {})[currency] ||= begin
        url = PAGES.fetch(currency) { raise Error, "Unknown currency #{currency}" }
        body, status = get(url)
        if body.to_s.match?(CHALLENGE_RE)
          raise Error.new("apecon.ru answered with a bot check (sgcaptcha) instead of the page — " \
                          "this host's IP is being challenged, so the page cannot be read from here",
                          http_status: status)
        end

        doc = parse_html(body)
        { quote: attempt_parse { parse_quote(doc, currency) },
          forecast: attempt_parse { parse_forecast(doc) },
          shape: page_shape(doc, body), url: url, http_status: status }
      end
    end

    # The parsed value, or the captured Error when that half of the page
    # did not parse — the caller raises only for the half it actually needs.
    def attempt_parse
      yield
    rescue Error => e
      e
    end

    def demand(part, page)
      return part unless part.is_a?(Error)

      raise Error.new("#{part.message} (#{page[:shape]})", http_status: page[:http_status])
    end

    # What the page actually was, in one line. It goes into every error message
    # and from there into FetchLog: "not recognized" on its own cannot tell a
    # redesign apart from a stub page served to this IP.
    def page_shape(doc, body)
      rows = doc.css("table tr")
      months = rows.count { |tr| cells_of(tr).first.to_s.match?(MONTH_RE) }
      shape = "#{body.to_s.bytesize} B, #{doc.css('table').size} tables, " \
              "#{rows.size} rows, #{months} month rows"
      # No tables at all means we were handed something other than the page —
      # a redirect stub, a block notice. Quote it, or the next reader is left
      # guessing again.
      shape += ", body: #{snippet(body)}" if doc.css("table").empty?
      shape
    end

    def snippet(body)
      body.to_s.dup.force_encoding("utf-8").scrub.gsub(/[[:space:]]+/, " ").strip.truncate(200).inspect
    end

    # Base#get plus the mandatory pause between any two requests to the site.
    def get(url)
      self.class.respect_crawl_delay { super }
    end

    # The quote sits in a small table right under the «ДД.ММ.ГГГГ. Курс …
    # сегодня» headline: a row with a bare number followed by a percent cell.
    # The first such row in document order is the quote.
    def parse_quote(doc, currency)
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
      Nokogiri::HTML(body.to_s.dup.force_encoding("utf-8"))
    end

    # The monthly tables interleave two kinds of rows: a single-cell year header
    # («2026», «2028 продолжение») and data rows «Ммм | мин-макс | курс | %».
    # The month may also carry its own year («Авг 2026»). Rows are matched by
    # that shape, so cosmetic markup changes don't break the parser.
    def parse_forecast(doc)
      points, year, previous_month = [], nil, nil
      each_row(doc) do |cells|
        filled = cells.reject(&:empty?)
        # A year header is the only thing on its line — whether the cell spans
        # the table or the remaining cells are simply empty.
        if filled.size == 1 && (y = filled.first[/\A(\d{4})\b/, 1])
          year, previous_month = y.to_i, nil
        elsif (month = cells.first&.match(MONTH_RE)) && (range = cells[1]&.match(RANGE_RE))
          next unless cells[2]&.match?(NUMBER_RE)

          number = MONTHS.index(month[1].downcase) + 1
          if month[2] then year = month[2].to_i
          elsif year.nil? then year = Date.current.year
          # No header above and the month did not advance: the table rolled
          # over into the next year. Months here only ever run forward.
          elsif previous_month && number <= previous_month then year += 1
          end
          previous_month = number

          low, high = [ decimal(range[1]), decimal(range[2]) ].sort
          points << { horizon_date: Date.new(year, number, 1),
                      value: decimal(cells[2]), low: low, high: high }
        end
      end
      points.uniq { |p| p[:horizon_date] }
    rescue Date::Error => e
      raise Error, "Unexpected apecon page: #{e.message}"
    end

    # Yields every table row as an array of stripped cell texts, in document order.
    def each_row(doc)
      doc.css("table tr").each { |tr| yield cells_of(tr) }
    end

    def cells_of(tr)
      tr.css("th, td").map { |cell| cell.text.gsub(/[[:space:]]+/, " ").strip }
    end

    # "81.18" / "81,18" -> BigDecimal
    def decimal(str) = BigDecimal(str.strip.tr(",", "."))
  end
end
