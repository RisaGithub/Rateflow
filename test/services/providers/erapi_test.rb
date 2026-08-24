require "test_helper"

module Providers
  class ErapiTest < ActiveSupport::TestCase
    # Serves the saved JSON instead of hitting open.er-api.com.
    class Stubbed < Erapi
      private def get(_url)
        [ File.read(File.expand_path("../../fixtures/files/erapi_usd.json", __dir__)), 200 ]
      end
    end

    test "takes the date from time_last_update_utc, not from the local clock" do
      result = Stubbed.new.fetch(%w[USD EUR])

      assert_equal [ Date.new(2026, 6, 15) ], result.records.map { |r| r[:on_date] }.uniq
    end

    test "computes rates against RUB" do
      result = Stubbed.new.fetch(%w[USD EUR])

      by_currency = result.records.to_h { |r| [ r[:currency], r[:value] ] }
      assert_equal BigDecimal("78.9012"), by_currency["USD"]
      assert_equal (BigDecimal("78.9012") / BigDecimal("0.92")).round(4), by_currency["EUR"]
    end
  end
end
