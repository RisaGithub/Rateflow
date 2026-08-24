# One point inside a forecast snapshot: the predicted value for a date,
# optionally with a low–high range (АПЭКОН publishes one, our own model does not).
class ForecastPoint < ApplicationRecord
  belongs_to :forecast_run

  validates :horizon_date, presence: true
  validates :value, numericality: { greater_than: 0 }
end
