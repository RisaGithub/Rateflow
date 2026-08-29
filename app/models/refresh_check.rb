# Journal of the scheduled checks themselves, one row per ForecastsFetcher
# call — including the ones that decided everything was fresh and made no
# request at all. It answers "is the schedule still running?", which fetch_logs
# cannot: a skipped check is not an attempt to reach a provider, so recording
# it there would quietly worsen АПЭКОН's availability on /sources.
class RefreshCheck < ApplicationRecord
  KINDS = %w[forecast].freeze
  ORIGINS = %w[task endpoint].freeze
  OUTCOMES = %w[fetched skipped failed].freeze

  # The scheduled client outside the deployment runs hourly, so a couple of
  # hours of silence from origin "task" means the schedule itself is down.
  SILENCE_LIMIT = 2.hours

  validates :kind, inclusion: { in: KINDS }
  validates :origin, inclusion: { in: ORIGINS }
  validates :outcome, inclusion: { in: OUTCOMES }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_origin, ->(origin) { where(origin: origin) }
end
