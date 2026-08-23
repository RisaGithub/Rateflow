class CreateFetchLogs < ActiveRecord::Migration[8.1]
  def change
    create_table :fetch_logs do |t|
      t.string :provider, null: false
      t.boolean :ok, null: false, default: false
      t.integer :http_status
      t.integer :duration_ms, null: false, default: 0
      t.integer :records_count, null: false, default: 0
      t.text :error_message

      t.timestamps
    end

    add_index :fetch_logs, :created_at
  end
end
