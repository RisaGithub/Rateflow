class AddProviderCreatedAtIndexToFetchLogs < ActiveRecord::Migration[8.1]
  def change
    add_index :fetch_logs, %i[provider created_at]
  end
end
