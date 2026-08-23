class FetchLog < ApplicationRecord
  validates :provider, inclusion: { in: Rate::PROVIDERS }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :succeeded, -> { where(ok: true) }
  scope :failed, -> { where(ok: false) }
end
