module Providers
  # open.er-api.com — free, keyless, today's snapshot only (no history).
  # One request returns every currency, so it is fetched once per run.
  class Erapi < Base
    ENDPOINT = "https://open.er-api.com/v6/latest/USD"

    # The date range is accepted for interface parity but ignored: the API
    # only ever serves today's snapshot.
    def fetch(currencies, from: nil, to: nil)
      body, status = get(ENDPOINT)
      json = parse(body)
      rates = json.fetch("rates") { raise Error, "No rates in response" }
                  .transform_values { |v| BigDecimal(v.to_s) }
      rub = rates["RUB"] or raise Error, "No RUB in response"
      on_date = update_date(json)

      records = currencies.filter_map do |currency|
        base = rates[currency]
        next if base.nil? || base.zero?

        { currency: currency, on_date: on_date, value: (rub / base).round(4) }
      end

      Result.new(records: records, http_status: status)
    end

    private

    def parse(body)
      json = JSON.parse(body)
      raise Error, "API result: #{json['result']} #{json['error-type']}" unless json["result"] == "success"

      json
    rescue JSON::ParserError => e
      raise Error, "Unexpected ER-API payload: #{e.message}"
    end

    # The snapshot is stamped by the API itself ("Sat, 24 Aug 2026 00:02:31 +0000");
    # trusting it instead of the local clock keeps the date right across midnight.
    def update_date(json)
      Time.rfc2822(json.fetch("time_last_update_utc")).utc.to_date
    rescue KeyError, ArgumentError => e
      raise Error, "Unexpected ER-API payload: #{e.message}"
    end
  end
end
