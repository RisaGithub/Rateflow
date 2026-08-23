module Providers
  # Bank of Russia daily dynamics, one currency per request.
  # https://www.cbr.ru/scripts/XML_dynamic.asp
  class Cbr < Base
    ENDPOINT = "https://www.cbr.ru/scripts/XML_dynamic.asp"
    IDS = { "USD" => "R01235", "EUR" => "R01239", "CNY" => "R01375", "GBP" => "R01035" }.freeze

    def fetch(currency, from:, to:)
      id = IDS.fetch(currency) { raise Error, "Unknown currency #{currency}" }
      url = "#{ENDPOINT}?date_req1=#{fmt(from)}&date_req2=#{fmt(to)}&VAL_NM_RQ=#{id}"
      body, status = get(url)

      Result.new(records: parse(body, currency), http_status: status)
    end

    private

    def fmt(date) = date.strftime("%d/%m/%Y")

    def parse(body, currency)
      xml = body.dup.force_encoding("windows-1251").encode("utf-8")
      doc = Nokogiri::XML(xml)
      raise Error, "XML parse error: #{doc.errors.first}" if doc.errors.any?

      doc.xpath("//Record").map do |rec|
        nominal = decimal(rec.at("Nominal").text)
        value = decimal(rec.at("Value").text)
        {
          currency: currency,
          on_date: Date.strptime(rec["Date"], "%d.%m.%Y"),
          value: (value / nominal).round(4)
        }
      end
    rescue Date::Error, ArgumentError, NoMethodError => e
      raise Error, "Unexpected CBR payload: #{e.message}"
    end

    # "71,5532" -> BigDecimal("71.5532")
    def decimal(str) = BigDecimal(str.strip.tr(",", "."))
  end
end
