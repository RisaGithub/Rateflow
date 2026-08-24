# Pulls rates for every currency from all four providers on every run.
#
# The providers are equals: each one is asked every time, each attempt is
# recorded in FetchLog (one entry per provider per run), and each provider's
# rows are stored under its own key. One provider failing never stops the
# others. Rows are upserted, so re-running is idempotent.
class RatesFetcher
  def initialize(days: 14, currencies: Rate::CURRENCIES, providers: nil)
    @from = days.days.ago.to_date
    @to = Date.current
    @currencies = currencies
    @providers = providers || [ Providers::Cbr.new, Providers::Erapi.new, Providers::Currencyapi.new, Providers::Apecon.new ]
  end

  # Returns total number of rows written.
  def call
    @providers.sum do |provider|
      Rate.store(attempt(provider) { provider.fetch(@currencies, from: @from, to: @to) }, provider.key)
    end
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

  def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
end
