# Read-side view model for the dashboard page: the full 90-day series for the
# client-side chart and per-currency card summaries.
class Dashboard
  NAMES = { "USD" => "Доллар США", "EUR" => "Евро", "CNY" => "Китайский юань", "GBP" => "Фунт стерлингов" }.freeze
  DAYS = 90
  SPARK_DAYS = 30

  Card = Struct.new(:code, :name, :value, :delta, :pct, :on_date, :provider, :spark, keyword_init: true)

  def initialize
    @rates = Rate.since(DAYS.days.ago.to_date).chronological.to_a
  end

  # { "USD" => { "cbr" => [["2026-06-01", 71.55], ...], "erapi" => [...] }, ... }
  def series
    @series ||= Rate::CURRENCIES.to_h do |cur|
      [ cur, Rate::PROVIDERS.to_h { |prov| [ prov, points(cur, prov) ] } ]
    end
  end

  def cards
    Rate::CURRENCIES.map { |cur| card(cur) }
  end

  private

  def points(currency, provider)
    @rates.select { |r| r.currency == currency && r.provider == provider }
          .map { |r| [ r.on_date.iso8601, r.value.to_f ] }
  end

  # Cards follow the primary source; ER-API steps in only if CBR has nothing.
  def card(currency)
    provider = Rate::PROVIDERS.find { |p| series[currency][p].any? }
    return Card.new(code: currency, name: NAMES[currency]) unless provider

    pts = series[currency][provider]
    last, prev = pts[-1], pts[-2]
    delta = prev ? last[1] - prev[1] : nil

    Card.new(
      code: currency, name: NAMES[currency], value: last[1], on_date: Date.parse(last[0]),
      provider: provider, delta: delta, pct: (delta && prev[1] > 0 ? delta / prev[1] * 100 : nil),
      spark: pts.select { |d, _| d >= SPARK_DAYS.days.ago.to_date.iso8601 }.map(&:last)
    )
  end
end
