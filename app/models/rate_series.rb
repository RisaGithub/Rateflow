# Read model behind GET /series: per-provider [date, value] points for one
# currency and date range, downsampled when the range holds too many points.
class RateSeries
  MAX_POINTS = 400

  def initialize(currency:, providers:, from: nil, to: nil)
    @currency = currency
    @providers = providers
    @from = from
    @to = to
  end

  # { currency:, from:, to:, series: { "cbr" => { points: [[iso, float], ...], total: n } } }
  def as_json(*)
    {
      currency: @currency,
      from: @from&.iso8601,
      to: @to&.iso8601,
      series: @providers.index_with { |provider| provider_series(provider) }
    }
  end

  private

  def provider_series(provider)
    points = scope(provider).pluck(:on_date, :value).map { |d, v| [ d.iso8601, v.to_f ] }
    { points: thin(points), total: points.size }
  end

  def scope(provider)
    scope = Rate.for(@currency, provider).chronological
    scope = scope.where(on_date: @from..) if @from
    scope = scope.where(on_date: ..@to) if @to
    scope
  end

  # Keep every Nth point counting back from the end so the newest point always
  # survives; short ranges pass through untouched.
  def thin(points)
    return points if points.size <= MAX_POINTS

    step = (points.size.to_f / MAX_POINTS).ceil
    points.reverse.each_slice(step).map(&:first).reverse
  end
end
