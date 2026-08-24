# Read-side view model for the dashboard page: per-currency card summaries and
# the initial chart payload. Everything is fetched with narrow SQL queries —
# the full history never gets loaded into memory; later chart switches go
# through GET /series.
class Dashboard
  NAMES = { "USD" => "Доллар США", "EUR" => "Евро", "CNY" => "Китайский юань", "GBP" => "Фунт стерлингов" }.freeze
  DEFAULT_DAYS = 30
  SPARK_DAYS = 30

  Card = Struct.new(:code, :name, :value, :delta, :pct, :on_date, :provider, :spark, keyword_init: true)

  def cards
    @cards ||= Rate::CURRENCIES.map { |cur| card(cur) }
  end

  # { "USD" => 82.92, ... } — the rate each card shows, used by the converter.
  def latest_rates
    cards.select(&:value).to_h { |c| [ c.code, c.value ] }
  end

  # Embedded in the page for the first paint (default chart state).
  def initial_series
    RateSeries.new(currency: Rate::CURRENCIES.first, providers: Rate::PROVIDERS,
                   from: DEFAULT_DAYS.days.ago.to_date).as_json
  end

  private

  # Cards follow provider priority: CBR first, the other two step in only
  # when it has nothing for the currency.
  def card(currency)
    provider = Rate::PROVIDERS.find { |p| Rate.for(currency, p).exists? }
    return Card.new(code: currency, name: NAMES[currency]) unless provider

    last, prev = Rate.for(currency, provider).order(on_date: :desc).limit(2).to_a
    delta = prev && (last.value - prev.value).to_f

    Card.new(
      code: currency, name: NAMES[currency], value: last.value.to_f, on_date: last.on_date,
      provider: provider, delta: delta, pct: (delta && prev.value.positive? ? delta / prev.value.to_f * 100 : nil),
      spark: Rate.for(currency, provider).since(SPARK_DAYS.days.ago.to_date).chronological.pluck(:value).map(&:to_f)
    )
  end
end
