module Providers
  # Result of one provider call: parsed rate rows + the HTTP status we got.
  Result = Struct.new(:records, :http_status, keyword_init: true)
end
