require "test_helper"

class DashboardTest < ActiveSupport::TestCase
  def rate(provider, value, on_date: Date.current)
    Rate.create!(provider: provider, currency: "USD", on_date: on_date, value: value)
  end

  def usd_card = Dashboard.new.cards.find { |c| c.code == "USD" }

  test "card prefers CBR whenever it has any data" do
    rate("cbr", "80.1", on_date: Date.current - 2) # e.g. Friday before a weekend
    rate("currencyapi", "80.5")
    rate("apecon", "83.0")

    card = usd_card
    assert_equal "cbr", card.provider
    assert_equal 80.1, card.value
  end

  test "without CBR the card takes currencyapi, never the scraped apecon quote" do
    rate("erapi", "80.3")
    rate("currencyapi", "80.5")
    rate("apecon", "83.0")

    card = usd_card
    assert_equal "currencyapi", card.provider
    assert_equal 80.5, card.value
    assert_equal Date.current, card.on_date # the card names this provider and date
  end

  test "apecon is the last resort when it is the only source" do
    rate("apecon", "83.0")

    assert_equal "apecon", usd_card.provider
  end
end
