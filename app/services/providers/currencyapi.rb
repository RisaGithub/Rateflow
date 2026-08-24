module Providers
  # Currency API (github.com/fawazahmed0/exchange-api) — free, keyless.
  # Serves both a "latest" snapshot and per-date snapshots; jsDelivr is the
  # primary CDN with a Cloudflare Pages mirror as backup. All keys lowercase.
  class Currencyapi < Base
    PRIMARY = "https://cdn.jsdelivr.net/npm/@fawazahmed0/currency-api@%{version}/v1/currencies/usd.json"
    FALLBACK = "https://%{version}.currency-api.pages.dev/v1/currencies/usd.json"

    # Raised when a dated snapshot simply does not exist (HTTP 404) — callers
    # backfilling history should skip that day, not treat it as a failure.
    class NotFound < Error; end

    # `on: nil` fetches the latest snapshot; `on: date` a specific day.
    # The from/to range is accepted for interface parity but ignored.
    def fetch(currencies, on: nil, from: nil, to: nil)
      version = on ? on.iso8601 : "latest"
      body, status = get_with_fallback(version, dated: !on.nil?)
      json = parse(body)
      usd = json.fetch("usd") { raise Error, "No usd key in response" }
      rub = usd["rub"] or raise Error, "No rub in response"

      on_date = Date.iso8601(json.fetch("date") { raise Error, "No date in response" })
      records = currencies.filter_map do |currency|
        base = decimal(usd[currency.downcase])
        next if base.nil? || base.zero?

        { currency: currency, on_date: on_date, value: (BigDecimal(rub.to_s) / base).round(4) }
      end

      Result.new(records: records, http_status: status)
    rescue Date::Error => e
      raise Error, "Unexpected Currency API payload: #{e.message}"
    end

    private

    def get_with_fallback(version, dated:)
      get(format(PRIMARY, version: version))
    rescue Error => primary_error
      begin
        get(format(FALLBACK, version: version))
      rescue Error => e
        # 404 from both CDNs on a dated request means the day has no data.
        statuses = [ primary_error.http_status, e.http_status ]
        raise NotFound.new("No snapshot for #{version}", http_status: 404) if dated && statuses.include?(404)

        raise e
      end
    end

    def parse(body)
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise Error, "Unexpected Currency API payload: #{e.message}"
    end

    def decimal(value)
      value.nil? ? nil : BigDecimal(value.to_s)
    end
  end
end
