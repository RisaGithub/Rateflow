# One forecast snapshot: who predicted, for which currency, and when the
# snapshot was taken. Points live in forecast_points; snapshots are never
# overwritten, so the full history of how a forecast evolved is preserved.
class ForecastRun < ApplicationRecord
  PROVIDERS = %w[apecon internal].freeze

  has_many :points, class_name: "ForecastPoint", dependent: :delete_all

  validates :provider, inclusion: { in: PROVIDERS }
  validates :currency, inclusion: { in: Rate::CURRENCIES }
  validates :captured_at, presence: true

  scope :for, ->(currency, provider) { where(currency: currency, provider: provider) }
  scope :chronological, -> { order(:captured_at) }

  def self.latest_for(currency, provider)
    self.for(currency, provider).order(captured_at: :desc).first
  end

  # Stores one snapshot with dedup: when the new points are identical to the
  # latest stored snapshot, only its captured_at is bumped — otherwise a daily
  # cron would pile up dozens of equal versions and playback would show nothing.
  # `points` is an array of {horizon_date:, value:, low:, high:}.
  # Returns the run, freshly created or refreshed.
  def self.store(provider:, currency:, points:, source_url: nil, captured_at: Time.current)
    raise ArgumentError, "empty forecast" if points.empty?

    last = latest_for(currency, provider)
    if last&.same_points?(points)
      last.update!(captured_at: captured_at)
      return last
    end

    transaction do
      run = create!(provider: provider, currency: currency, captured_at: captured_at,
                    source_url: source_url, points_count: points.size)
      ForecastPoint.insert_all!(points.map { |p| p.slice(:horizon_date, :value, :low, :high).merge(forecast_run_id: run.id) })
      run
    end
  end

  # Dedup hinges on this: values are compared at the precision the column
  # actually stores, so a forecast recomputed from unchanged data reads as the
  # same snapshot instead of piling up a new version on every run.
  def same_points?(new_points)
    stored = points.order(:horizon_date).pluck(:horizon_date, :value, :low, :high)
    fresh = new_points.map { |p| [ p[:horizon_date], big(p[:value]), big(p[:low]), big(p[:high]) ] }.sort_by(&:first)
    stored == fresh
  end

  def self.value_scale = @value_scale ||= ForecastPoint.columns_hash["value"].scale

  private

  def big(value) = value.nil? ? nil : BigDecimal(value.to_s).round(self.class.value_scale)
end
