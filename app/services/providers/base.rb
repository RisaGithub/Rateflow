require "net/http"

module Providers
  # Raised for any failure talking to a provider (network, HTTP, parsing).
  class Error < StandardError
    attr_reader :http_status

    def initialize(message, http_status: nil)
      super(message)
      @http_status = http_status
    end
  end

  # Result of one provider call: parsed rate rows + the HTTP status we got.
  Result = Struct.new(:records, :http_status, keyword_init: true)

  class Base
    TIMEOUT = 10

    def self.key
      name.demodulize.downcase
    end

    def key = self.class.key

    private

    # GET a URL with a hard timeout. Returns [body, status].
    # Any network-level failure is wrapped into Providers::Error.
    def get(url)
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == "https"
      http.open_timeout = TIMEOUT
      http.read_timeout = TIMEOUT

      response = http.get(uri.request_uri, { "User-Agent" => "Rateflow/1.0" })
      status = response.code.to_i
      raise Error.new("HTTP #{status}", http_status: status) unless response.is_a?(Net::HTTPSuccess)

      [ response.body, status ]
    rescue Error
      raise
    rescue SocketError, Timeout::Error, IOError, SystemCallError, OpenSSL::SSL::SSLError => e
      raise Error, "#{e.class}: #{e.message}"
    end
  end
end
