Rails.application.routes.draw do
  root "dashboard#show"
  get "series", to: "series#show"
  get "forecasts", to: "forecasts#show"
  get "sources", to: "sources#show"

  get "cron/refresh", to: "cron#refresh"
  get "cron/forecasts", to: "cron#forecasts"

  get "admin", to: "admin#show"
  post "admin/refresh_rates", to: "admin#refresh_rates", as: :admin_refresh_rates
  post "admin/backfill_year", to: "admin#backfill_year", as: :admin_backfill_year
  post "admin/refresh_forecasts", to: "admin#refresh_forecasts", as: :admin_refresh_forecasts
  post "admin/rebuild_internal", to: "admin#rebuild_internal", as: :admin_rebuild_internal

  get "up" => "rails/health#show", as: :rails_health_check
end
