# Rateflow's own naive forecast, moved server-side from forecast.js so it is
# stored as versioned snapshots like АПЭКОН's and can be compared with facts.
#
# Same model as before: extend the series by HORIZON daily steps, each new
# point being the rolling mean of the previous WINDOW values (actual or
# already forecast). The browser only draws the result now.
class InternalForecast
  WINDOW = 7
  HORIZON = 7

  def initialize(currencies: Rate::CURRENCIES)
    @currencies = currencies
  end

  # Snapshots every currency; ForecastRun.store dedups unchanged forecasts.
  # Returns the number of currencies that produced a snapshot.
  def call
    @currencies.count { |currency| snapshot(currency) }
  end

  # Builds and stores one snapshot; nil when there is not enough history.
  def snapshot(currency)
    provider = source_provider(currency)
    return nil unless provider

    dates, values = Rate.for(currency, provider).chronological.pluck(:on_date, :value).transpose
    ForecastRun.store(provider: "internal", currency: currency, points: points_for(dates, values))
  end

  # Forecast points continuing the given series — shared with the historical
  # backtest so replayed forecasts use exactly the live model.
  def points_for(dates, values)
    project(values.map(&:to_f)).each_with_index.map do |value, i|
      { horizon_date: dates.last + i + 1, value: value.round(4), low: nil, high: nil }
    end
  end

  private

  # Same priority as the dashboard cards: the first provider with enough data.
  def source_provider(currency)
    Rate::PROVIDERS.find { |p| Rate.for(currency, p).count >= WINDOW + 1 }
  end

  # Rolling-mean continuation — the exact logic previously in forecast.js.
  def project(values)
    buf = values.last(WINDOW)
    HORIZON.times.map do
      nxt = buf.sum / buf.size
      buf = buf.drop(1) + [ nxt ]
      nxt
    end
  end
end
