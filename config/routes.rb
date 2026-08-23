Rails.application.routes.draw do
  root "dashboard#show"
  get "sources", to: "sources#show"

  get "up" => "rails/health#show", as: :rails_health_check
end
