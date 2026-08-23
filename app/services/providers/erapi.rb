module Providers
  # open.er-api.com — free, keyless, today's snapshot only (no history).
  # One request returns every currency, so it is fetched once per run.
  class Erapi < Base
    ENDPOINT = "https://open.er-api.com/v6/latest/USD"

    def fetch(currencies)
      body, status = get(ENDPOINT)
      rates = parse(body)
      rub = rates["RUB"] or raise Error, "No RUB in response"

      records = currencies.filter_map do |currency|
        base = rates[currency]
        next if base.nil? || base.zero?

        { currency: currency, on_date: Date.current, value: (rub / base).round(4) }
      end

      Result.new(records: records, http_status: status)
    end

    private

    def parse(body)
      json = JSON.parse(body)
      raise Error, "API result: #{json['result']} #{json['error-type']}" unless json["result"] == "success"

      json.fetch("rates").transform_values { |v| BigDecimal(v.to_s) }
    rescue JSON::ParserError, KeyError => e
      raise Error, "Unexpected ER-API payload: #{e.message}"
    end
  end
end
