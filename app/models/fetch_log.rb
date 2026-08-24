class FetchLog < ApplicationRecord
  KINDS = %w[rates forecast].freeze

  validates :provider, inclusion: { in: Rate::PROVIDERS }
  validates :kind, inclusion: { in: KINDS }

  scope :recent, -> { order(created_at: :desc) }
  scope :for_provider, ->(provider) { where(provider: provider) }
  scope :for_kind, ->(kind) { where(kind: kind) }
  scope :succeeded, -> { where(ok: true) }
  scope :failed, -> { where(ok: false) }
end
