class DashboardController < ApplicationController
  def show
    @dashboard = Dashboard.new
    @accuracy = ForecastAccuracy.new.reports
  end
end
