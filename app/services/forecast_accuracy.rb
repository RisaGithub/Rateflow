# Honest scoring of matured forecasts: every stored forecast point whose
# horizon date has passed is compared with the CBR fact for that exact date.
# Points "predicting" a date at or before their own capture time are excluded —
# АПЭКОН's current-month row is hindsight, not a forecast.
#
# Versioned snapshots make this fair: each version's miss counts separately,
# bucketed by how far ahead the prediction was made.
class ForecastAccuracy
  FACT_PROVIDER = "cbr"
  BUCKETS = [ [ "до 7 дней", 1..7 ], [ "8–30 дней", 8..30 ], [ "30+ дней", 31.. ] ].freeze

  Report = Struct.new(:provider, :samples, :mae, :mape, :buckets, keyword_init: true)

  # Optional currency narrows the scoring to one currency — the forecasts page
  # shows a report per currency so its shared currency switch applies here too.
  # Optional from/to keep only points whose horizon date falls inside them,
  # matching the page's period switch and custom range. Scoring never reaches
  # past today regardless of to — the future has no fact yet.
  def initialize(currency: nil, from: nil, to: nil)
    @currency = currency
    @from = from
    @to = to
  end

  def reports
    ForecastRun::PROVIDERS.map { |provider| report(provider) }
  end

  def report(provider)
    errors = errors_for(provider)
    buckets = BUCKETS.map { |label, range| [ label, summarize(errors.select { |e| range.cover?(e[:lead]) }) ] }
    Report.new(provider: provider, **summarize(errors), buckets: buckets)
  end

  private

  # [{abs:, pct:, lead:}, ...] — one entry per matured, comparable point.
  def errors_for(provider)
    points = ForecastPoint.joins(:forecast_run)
                          .where(forecast_runs: { provider: provider, currency: @currency || Rate::CURRENCIES })
                          .where(horizon_date: @from..[ @to, Date.current ].compact.min)
                          .pluck(:horizon_date, :value, "forecast_runs.currency", "forecast_runs.captured_at")
    return [] if points.empty?

    facts = facts_for(points)
    points.filter_map do |horizon_date, value, currency, captured_at|
      lead = (horizon_date - captured_at.to_date).to_i
      fact = facts[[ currency, horizon_date ]]
      next unless lead.positive? && fact

      abs = (value - fact).abs.to_f
      { abs: abs, pct: abs / fact.to_f * 100, lead: lead }
    end
  end

  # CBR rates for every (currency, date) pair the points may need.
  def facts_for(points)
    dates = points.map(&:first)
    Rate.where(provider: FACT_PROVIDER, on_date: dates.min..dates.max)
        .pluck(:currency, :on_date, :value)
        .to_h { |currency, on_date, value| [ [ currency, on_date ], value ] }
  end

  def summarize(errors)
    return { samples: 0, mae: nil, mape: nil } if errors.empty?

    {
      samples: errors.size,
      mae: (errors.sum { |e| e[:abs] } / errors.size).round(4),
      mape: (errors.sum { |e| e[:pct] } / errors.size).round(2)
    }
  end
end
