# Keeps the two append-only tables from growing forever. Fetch logs older
# than ~3 months carry no value: the sources page only shows recent attempts.
# Internal forecast snapshots are reproducible — the model is deterministic
# and forecasts:backtest can replay them from CBR facts at any time — so
# copies older than a year go too. АПЭКОН snapshots are never touched: they
# were scraped at a moment in time and cannot be recovered.
class LogsPruner
  DEFAULT_DAYS = 90
  INTERNAL_SNAPSHOT_DAYS = 365

  def initialize(days: DEFAULT_DAYS, snapshot_days: INTERNAL_SNAPSHOT_DAYS)
    @days = days
    @snapshot_days = snapshot_days
  end

  # Returns { fetch_logs:, internal_runs: } — how many rows were removed.
  def call
    { fetch_logs: FetchLog.where(created_at: ...@days.days.ago).delete_all,
      internal_runs: prune_internal_runs }
  end

  private

  def prune_internal_runs
    runs = ForecastRun.where(provider: "internal", captured_at: ...@snapshot_days.days.ago)
    ForecastRun.transaction do
      ForecastPoint.where(forecast_run: runs).delete_all
      runs.delete_all
    end
  end
end
