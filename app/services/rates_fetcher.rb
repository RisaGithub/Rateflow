# Pulls rates for every currency and records every provider call in FetchLog.
#
# CBR is the primary source and is asked per currency for the whole date range.
# ER-API is asked once per run (a single request covers all currencies) and plays
# two roles: the fallback for any currency CBR failed to deliver, and a daily
# reference snapshot so the dashboard can show how the two sources diverge.
# Rows are upserted, so re-running is idempotent.
class RatesFetcher
  def initialize(days: 90, currencies: Rate::CURRENCIES)
    @from = days.days.ago.to_date
    @to = Date.current
    @currencies = currencies
  end

  # Returns total number of rows written.
  def call
    cbr = Providers::Cbr.new
    written = @currencies.sum { |c| store(attempt(cbr) { cbr.fetch(c, from: @from, to: @to) }, cbr.key) }

    erapi = Providers::Erapi.new
    written + store(attempt(erapi) { erapi.fetch(@currencies) }, erapi.key)
  end

  private

  # Runs one provider call, logs the outcome, returns records ([] on failure).
  def attempt(provider)
    started = now_ms
    result = yield
    empty = result.records.empty?
    log(provider, started, ok: !empty, status: result.http_status,
        count: result.records.size, error: ("Empty response" if empty))
    result.records
  rescue Providers::Error => e
    log(provider, started, ok: false, status: e.http_status, error: e.message)
    []
  rescue StandardError => e
    # Anything unexpected must not take the app down — record it and move on.
    log(provider, started, ok: false, error: "#{e.class}: #{e.message}")
    []
  end

  def log(provider, started, ok:, status: nil, count: 0, error: nil)
    FetchLog.create!(
      provider: provider.key, ok: ok, http_status: status, duration_ms: now_ms - started,
      records_count: count, error_message: error&.truncate(1000)
    )
  end

  def store(records, provider)
    return 0 if records.empty?

    rows = records.map { |r| r.merge(provider: provider) }
    Rate.upsert_all(rows, unique_by: %i[currency on_date provider])
    rows.size
  end

  def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
end
