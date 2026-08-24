require "test_helper"

module Providers
  class CurrencyapiTest < ActiveSupport::TestCase
    # Serves the saved JSON instead of hitting the CDN.
    class Stubbed < Currencyapi
      private def get(_url)
        [ File.read(File.expand_path("../../fixtures/files/currencyapi_usd.json", __dir__)), 200 ]
      end
    end

    test "computes rate as usd.rub divided by usd[x] with lowercase keys" do
      result = Stubbed.new.fetch(%w[USD EUR CNY GBP])

      by_currency = result.records.to_h { |r| [ r[:currency], r[:value] ] }
      assert_equal BigDecimal("72.2185"), by_currency["USD"]
      assert_equal (BigDecimal("72.21854799") / BigDecimal("0.86")).round(4), by_currency["EUR"]
      assert_equal (BigDecimal("72.21854799") / BigDecimal("7.1")).round(4), by_currency["CNY"]
      assert_equal (BigDecimal("72.21854799") / BigDecimal("0.74")).round(4), by_currency["GBP"]
    end

    test "takes the date from the payload" do
      result = Stubbed.new.fetch(%w[USD])

      assert_equal [ Date.new(2026, 6, 15) ], result.records.map { |r| r[:on_date] }.uniq
    end
  end
end
