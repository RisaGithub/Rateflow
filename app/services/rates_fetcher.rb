# Pulls rates for every currency from the three API providers on every run.
#
# The providers are equals: each one is asked every time, each attempt is
# recorded in FetchLog (one entry per provider per run), and each provider's
# rows are stored under its own key. One provider failing never stops the
# others. Rows are upserted, so re-running is idempotent.
#
# АПЭКОН is deliberately not here: its 10-second crawl delay per currency
# would stretch the request by half a minute, and its quote adds nothing over
# CBR. The apecon quote is stored by ForecastsFetcher instead, riding on the
# same page load as the forecast.
class RatesFetcher
  # How many rows the providers handed over in the last run, against the
  # written count #call returns. On a quiet run received is the usual ~170 and
  # written is 0 — Rate.store skips everything that has not moved.
  attr_reader :received

  def initialize(days: 14, currencies: Rate::CURRENCIES, providers: nil)
    @from = days.days.ago.to_date
    @to = Date.current
    @currencies = currencies
    @providers = providers || [ Providers::Cbr.new, Providers::Erapi.new, Providers::Currencyapi.new ]
  end

  # Returns total number of rows written — which is 0 when every provider
  # merely resent numbers already stored.
  def call
    @received = 0
    written = @providers.sum do |provider|
      records = attempt(provider) { provider.fetch(@currencies, from: @from, to: @to) }
      @received += records.size
      Rate.store(records, provider.key)
    end
    refresh_internal_forecast if written.positive?
    written
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

  # A run that actually wrote something re-snapshots our own forecast (deduped
  # inside), so the internal forecast history tracks the data it was built
  # from. A run that changed nothing skips it entirely. Its failure must not
  # sink the fetch itself.
  def refresh_internal_forecast
    InternalForecast.new(currencies: @currencies).call
  rescue StandardError => e
    Rails.logger.error("InternalForecast failed: #{e.class}: #{e.message}")
  end

  def log(provider, started, ok:, status: nil, count: 0, error: nil)
    FetchLog.create!(
      provider: provider.key, ok: ok, http_status: status, duration_ms: now_ms - started,
      records_count: count, error_message: error&.truncate(1000)
    )
  end

  def now_ms = Process.clock_gettime(Process::CLOCK_MONOTONIC, :millisecond)
end
