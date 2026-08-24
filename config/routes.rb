Rails.application.routes.draw do
  root "dashboard#show"
  get "series", to: "series#show"
  get "forecasts", to: "forecasts#show"
  get "sources", to: "sources#show"

  get "cron/refresh", to: "cron#refresh"
  get "cron/forecasts", to: "cron#forecasts"

  get "up" => "rails/health#show", as: :rails_health_check
end
