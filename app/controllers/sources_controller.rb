class SourcesController < ApplicationController
  LOG_LIMIT = 50

  def show
    @providers = Rate::PROVIDERS.map { |key| ProviderStatus.new(key) }
    @provider = params[:provider].presence_in(Rate::PROVIDERS)
    @status = params[:status].presence_in(%w[ok fail])

    logs = FetchLog.recent
    logs = logs.for_provider(@provider) if @provider
    logs = @status == "ok" ? logs.succeeded : logs.failed if @status
    @logs = logs.limit(LOG_LIMIT)
  end
end
