# Read model behind GET /forecasts/data: stored snapshots (run + points) for
# one currency, per provider — the payload the charts draw, the playback
# slider scrubs through and the snapshot table lists.
#
# The backtest left internal with hundreds of snapshots, so `runs` (the ones
# carrying points) are thinned to MAX_RUNS with the newest always kept;
# `index` stays complete but holds metadata only — the table shows every
# snapshot without dragging every point into the JSON.
class ForecastSeries
  MAX_RUNS = 100

  # Optional from/to keep only snapshots captured inside those dates — the
  # page's period switch and custom range filter every block by capture date.
  def initialize(currency:, providers: ForecastRun::PROVIDERS, latest_only: false, from: nil, to: nil)
    @currency = currency
    @providers = providers
    @latest_only = latest_only
    @from = from
    @to = to
  end

  # { currency:, empty:, series: { "apecon" => { runs: [...], index: [ { id:,
  #   captured_at:, points_count:, horizon_to: } ] } } }
  # With latest_only only the newest run per provider and no index — the
  # dashboard teaser needs nothing more. `empty` says no provider has ever
  # stored a snapshot, which is what raises the page's first-run notice; it is
  # about the whole table, not about this currency or period.
  def as_json(*)
    { currency: @currency, empty: ForecastRun.none?,
      series: @providers.index_with { |provider| provider_series(provider) } }
  end

  # One full snapshot in the same shape as a `runs` entry — for the table's
  # "show this exact version" click when the run was thinned out of the payload.
  def self.run_as_json(run)
    {
      id: run.id,
      provider: run.provider,
      captured_at: run.captured_at.iso8601,
      source_url: run.source_url,
      points: run.points.sort_by(&:horizon_date).map do |p|
        [ p.horizon_date.iso8601, p.value.to_f, p.low&.to_f, p.high&.to_f ]
      end
    }
  end

  private

  def provider_series(provider)
    scope = ForecastRun.for(@currency, provider).chronological
    scope = scope.where(captured_at: @from.in_time_zone..) if @from
    scope = scope.where(captured_at: ..@to.in_time_zone.end_of_day) if @to
    runs = scope.to_a
    return { runs: full_runs(runs.last(1)) } if @latest_only

    { runs: full_runs(thin(runs)), index: index(runs) }
  end

  def full_runs(runs)
    ForecastRun.where(id: runs.map(&:id)).chronological.includes(:points)
               .map { |run| self.class.run_as_json(run).except(:provider) }
  end

  # Metadata for every snapshot, oldest first, one grouped query for the horizons.
  def index(runs)
    horizons = ForecastPoint.where(forecast_run_id: runs.map(&:id))
                            .group(:forecast_run_id).maximum(:horizon_date)
    runs.map do |run|
      { id: run.id, captured_at: run.captured_at.iso8601,
        points_count: run.points_count, horizon_to: horizons[run.id]&.iso8601 }
    end
  end

  # Evenly sampled MAX_RUNS snapshots; the first and the newest always survive.
  def thin(runs)
    return runs if runs.size <= MAX_RUNS

    last = runs.size - 1
    (0...MAX_RUNS).map { |i| runs[(i * last.to_f / (MAX_RUNS - 1)).round] }.uniq
  end
end
