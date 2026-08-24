# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_08_24_120000) do
  # These are extensions that must be enabled in order to support this database
  enable_extension "pg_catalog.plpgsql"

  create_table "fetch_logs", force: :cascade do |t|
    t.datetime "created_at", null: false
    t.integer "duration_ms", default: 0, null: false
    t.text "error_message"
    t.integer "http_status"
    t.boolean "ok", default: false, null: false
    t.string "provider", null: false
    t.integer "records_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.index ["created_at"], name: "index_fetch_logs_on_created_at"
    t.index ["provider", "created_at"], name: "index_fetch_logs_on_provider_and_created_at"
  end

  create_table "forecast_points", force: :cascade do |t|
    t.bigint "forecast_run_id", null: false
    t.decimal "high", precision: 12, scale: 4
    t.date "horizon_date", null: false
    t.decimal "low", precision: 12, scale: 4
    t.decimal "value", precision: 12, scale: 4, null: false
    t.index ["forecast_run_id", "horizon_date"], name: "index_forecast_points_on_forecast_run_id_and_horizon_date", unique: true
    t.index ["forecast_run_id"], name: "index_forecast_points_on_forecast_run_id"
  end

  create_table "forecast_runs", force: :cascade do |t|
    t.datetime "captured_at", null: false
    t.datetime "created_at", null: false
    t.string "currency", null: false
    t.integer "points_count", default: 0, null: false
    t.string "provider", null: false
    t.string "source_url"
    t.datetime "updated_at", null: false
    t.index ["provider", "currency", "captured_at"], name: "index_forecast_runs_on_provider_and_currency_and_captured_at"
  end

  create_table "rates", force: :cascade do |t|
    t.datetime "created_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.string "currency", null: false
    t.date "on_date", null: false
    t.string "provider", null: false
    t.datetime "updated_at", default: -> { "CURRENT_TIMESTAMP" }, null: false
    t.decimal "value", precision: 12, scale: 4, null: false
    t.index ["currency", "provider", "on_date"], name: "index_rates_on_currency_and_provider_and_on_date", unique: true
  end

  add_foreign_key "forecast_points", "forecast_runs", on_delete: :cascade
end
