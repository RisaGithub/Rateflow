class Rate < ApplicationRecord
  CURRENCIES = %w[USD EUR CNY GBP].freeze
  PROVIDERS = %w[cbr erapi currencyapi apecon].freeze
  # Which provider's rate to show when several have data: the official CBR
  # first, then the API mirrors, and the АПЭКОН quote — a number scraped from
  # someone else's site — strictly last. Deliberately its own constant:
  # PROVIDERS is an unordered registry, this is a policy.
  SOURCE_PRIORITY = %w[cbr currencyapi erapi apecon].freeze

  validates :currency, inclusion: { in: CURRENCIES }
  validates :provider, inclusion: { in: PROVIDERS }
  validates :on_date, presence: true
  validates :value, numericality: { greater_than: 0 }

  scope :for, ->(currency, provider) { where(currency: currency, provider: provider) }
  scope :chronological, -> { order(:on_date) }
  scope :since, ->(date) { where(on_date: date..) }

  # Latest available date for a currency/provider pair.
  def self.latest_for(currency, provider)
    self.for(currency, provider).order(on_date: :desc).first
  end

  # Stores provider records ({currency:, on_date:, value:}); returns the number
  # of rows actually written.
  #
  # Providers resend two weeks of history on every run, so the vast majority of
  # a run is rows that already hold the same number. Rewriting them would bump
  # updated_at — the cache key behind /series and /dashboard/data — and make
  # RatesFetcher re-snapshot the internal forecast, both for nothing. So only
  # new and genuinely changed rows are upserted; an unchanged run never touches
  # the table at all.
  def self.store(records, provider)
    return 0 if records.empty?

    rows = changed_rows(records.map { |r| r.merge(provider: provider) }, provider)
    return 0 if rows.empty?

    upsert_all(rows, unique_by: %i[currency provider on_date], record_timestamps: true)
    rows.size
  end

  # Rows that are new or hold a different value. Values are compared as
  # BigDecimal rounded to the column's own scale: a float comparison, or one at
  # a finer precision than Postgres stores, would call every row changed on
  # every run — exactly the write the caller is trying to avoid.
  def self.changed_rows(rows, provider)
    stored = where(provider: provider, currency: rows.map { |r| r[:currency] }.uniq,
                   on_date: rows.map { |r| r[:on_date] }.uniq)
             .pluck(:currency, :on_date, :value)
             .to_h { |currency, on_date, value| [ [ currency, on_date ], value ] }

    rows.reject { |r| stored[[ r[:currency], r[:on_date].to_date ]] == scaled(r[:value]) }
  end

  # The precision Postgres keeps for a rate, straight from the schema.
  def self.value_scale = @value_scale ||= columns_hash["value"].scale

  def self.scaled(value) = BigDecimal(value.to_s).round(value_scale)

  private_class_method :changed_rows, :scaled
end
