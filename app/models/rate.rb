class Rate < ApplicationRecord
  CURRENCIES = %w[USD EUR CNY GBP].freeze
  PROVIDERS = %w[cbr erapi currencyapi].freeze

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
end
