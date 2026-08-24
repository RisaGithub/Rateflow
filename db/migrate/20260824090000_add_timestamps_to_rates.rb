class AddTimestampsToRates < ActiveRecord::Migration[8.1]
  def change
    # Existing rows get the migration time — the real insert time is unknown.
    add_timestamps :rates, null: false, default: -> { "CURRENT_TIMESTAMP" }
  end
end
