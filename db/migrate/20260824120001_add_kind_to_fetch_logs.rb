class AddKindToFetchLogs < ActiveRecord::Migration[8.1]
  def change
    add_column :fetch_logs, :kind, :string, null: false, default: "rates"
    add_index :fetch_logs, %i[kind created_at]
  end
end
