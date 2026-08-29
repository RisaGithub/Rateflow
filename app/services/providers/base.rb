require "net/http"

module Providers
  class Base
    TIMEOUT = 10
    USER_AGENT = "Rateflow/1.0 (+https://github.com/RisaGithub/Rateflow)".freeze
    # A request with no Accept at all reads as a crawler to many front-ends and
    # gets a stub page back. The User-Agent still says plainly who we are — the
    # point is to be a well-formed client, not to look like a browser.
    HEADERS = {
      "User-Agent" => USER_AGENT,
      "Accept" => "text/html,application/xhtml+xml,application/json;q=0.9,*/*;q=0.8",
      "Accept-Language" => "ru-RU,ru;q=0.9,en;q=0.8"
    }.freeze

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

      response = http.get(uri.request_uri, HEADERS)
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
