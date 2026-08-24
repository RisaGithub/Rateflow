# Read model behind GET /forecasts/data: every stored snapshot (run + its points)
# for one currency, per provider — the payload the chart draws and the
# version-playback slider scrubs through.
class ForecastSeries
  MAX_RUNS = 60 # playback needs recent history, not eternity — cap the payload

  def initialize(currency:, providers: ForecastRun::PROVIDERS)
    @currency = currency
    @providers = providers
  end

  # { currency:, series: { "apecon" => { runs: [ { captured_at:, source_url:,
  #   points: [[iso_date, value, low, high], ...] } ] } } }
  def as_json(*)
    { currency: @currency, series: @providers.index_with { |provider| { runs: runs(provider) } } }
  end

  private

  def runs(provider)
    scope = ForecastRun.for(@currency, provider).order(captured_at: :desc).limit(MAX_RUNS).includes(:points)
    scope.to_a.reverse.map do |run|
      {
        captured_at: run.captured_at.iso8601,
        source_url: run.source_url,
        points: run.points.sort_by(&:horizon_date).map do |p|
          [ p.horizon_date.iso8601, p.value.to_f, p.low&.to_f, p.high&.to_f ]
        end
      }
    end
  end
end
