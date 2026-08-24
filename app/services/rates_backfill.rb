# One-off archive load, safe to re-run (rows are upserted, never duplicated).
#
# CBR serves arbitrary ranges, so its history is pulled in year-sized slices
# per currency. Currency API only serves one date per request, so it is
# sampled weekly over the last two years. ER-API has no history at all.
# The default start is 1999: pre-denomination rates (~6000 ₽/$) would wreck
# the chart scale, so going deeper must be an explicit argument.
class RatesBackfill
  DEFAULT_FROM = Date.new(1999, 1, 1)
  CURRENCYAPI_YEARS = 2
  PAUSE = 0.3 # seconds between HTTP requests — be polite to other people's servers

  def initialize(from: DEFAULT_FROM, currencies: Rate::CURRENCIES, out: $stdout, pause: PAUSE)
    @from = from
    @to = Date.current
    @currencies = currencies
    @out = out
    @pause = pause
  end

  # Returns total number of rows written.
  def call
    backfill_cbr + backfill_currencyapi
  end

  private

  def backfill_cbr
    provider = Providers::Cbr.new
    @currencies.sum do |currency|
      year_slices.sum do |slice_from, slice_to|
        label = "cbr #{currency} #{slice_from}..#{slice_to}"
        request(label) do
          result = provider.fetch_currency(currency, from: slice_from, to: slice_to)
          Rate.store(result.records, provider.key)
        end
      end
    end
  end

  def backfill_currencyapi
    provider = Providers::Currencyapi.new
    from = [ @from, CURRENCYAPI_YEARS.years.ago.to_date ].max
    from.step(@to, 7).sum do |date|
      request("currencyapi #{date}") do
        result = provider.fetch(@currencies, on: date)
        Rate.store(result.records, provider.key)
      end
    end
  end

  # Runs one HTTP request, prints the outcome, pauses, returns rows written.
  # A day with no snapshot is normal; a failure is reported but never fatal.
  def request(label)
    written = yield
    @out.puts "#{label}: #{written} rows"
    written
  rescue Providers::Currencyapi::NotFound
    @out.puts "#{label}: no data, skipped"
    0
  rescue Providers::Error => e
    @out.puts "#{label}: FAILED #{e.message}"
    0
  ensure
    sleep @pause
  end

  # [[1999-01-01, 1999-12-31], [2000-01-01, ...], ..., [..., today]]
  def year_slices
    slices = []
    from = @from
    while from <= @to
      to = [ from + 1.year - 1.day, @to ].min
      slices << [ from, to ]
      from = to + 1.day
    end
    slices
  end
end
