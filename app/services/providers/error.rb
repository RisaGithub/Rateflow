module Providers
  # Raised for any failure talking to a provider (network, HTTP, parsing).
  class Error < StandardError
    attr_reader :http_status

    def initialize(message, http_status: nil)
      super(message)
      @http_status = http_status
    end
  end
end
