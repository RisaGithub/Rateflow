class CreateForecastTables < ActiveRecord::Migration[8.1]
  def change
    create_table :forecast_runs do |t|
      t.string :provider, null: false
      t.string :currency, null: false
      t.datetime :captured_at, null: false
      t.string :source_url
      t.integer :points_count, null: false, default: 0
      t.timestamps
      t.index %i[provider currency captured_at]
    end

    create_table :forecast_points do |t|
      t.references :forecast_run, null: false, foreign_key: { on_delete: :cascade }
      t.date :horizon_date, null: false
      t.decimal :value, precision: 12, scale: 4, null: false
      t.decimal :low, precision: 12, scale: 4
      t.decimal :high, precision: 12, scale: 4
      t.index %i[forecast_run_id horizon_date], unique: true
    end
  end
end
