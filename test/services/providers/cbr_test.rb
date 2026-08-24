require "test_helper"

module Providers
  class CbrTest < ActiveSupport::TestCase
    # Serves the saved windows-1251 XML instead of hitting cbr.ru.
    class Stubbed < Cbr
      private def get(_url)
        [ File.binread(File.expand_path("../../fixtures/files/cbr_usd.xml", __dir__)), 200 ]
      end
    end

    test "parses windows-1251 XML with comma decimals and nominal division" do
      result = Stubbed.new.fetch_currency("USD", from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 15))

      assert_equal 200, result.http_status
      assert_equal [
        { currency: "USD", on_date: Date.new(2026, 6, 1), value: BigDecimal("71.5532") },
        { currency: "USD", on_date: Date.new(2026, 6, 2), value: BigDecimal("72.1426") }
      ], result.records
    end

    test "aggregated fetch keeps going when nothing fails" do
      result = Stubbed.new.fetch(%w[USD], from: Date.new(2026, 6, 1), to: Date.new(2026, 6, 15))

      assert_equal 2, result.records.size
    end
  end
end
