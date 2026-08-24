class Rate < ApplicationRecord
  CURRENCIES = %w[USD EUR CNY GBP].freeze
  PROVIDERS = %w[cbr erapi currencyapi apecon].freeze

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

  # Upserts provider records ({currency:, on_date:, value:}); returns row count.
  # The unique index makes repeated loads idempotent.
  def self.store(records, provider)
    return 0 if records.empty?

    rows = records.map { |r| r.merge(provider: provider) }
    upsert_all(rows, unique_by: %i[currency provider on_date], record_timestamps: true)
    rows.size
  end
end
