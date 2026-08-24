class SourcesController < ApplicationController
  PER_PAGE = 50

  def show
    @providers = Rate::PROVIDERS.map { |key| ProviderStatus.new(key) }
    @provider = params[:provider].presence_in(Rate::PROVIDERS)
    @status = params[:status].presence_in(%w[ok fail])
    @page = [ params[:page].to_i, 1 ].max

    logs = FetchLog.recent
    logs = logs.for_provider(@provider) if @provider
    logs = @status == "ok" ? logs.succeeded : logs.failed if @status

    # One extra row tells us whether a next page exists without a COUNT query.
    page_plus_one = logs.offset((@page - 1) * PER_PAGE).limit(PER_PAGE + 1).to_a
    @next_page = page_plus_one.size > PER_PAGE ? @page + 1 : nil
    @logs = page_plus_one.first(PER_PAGE)
  end
end
