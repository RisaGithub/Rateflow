require "test_helper"
require "rake"

# The loop itself (order, pauses, quotes) is covered on ForecastsFetcher; here
# only the task's own concerns: argument handling and the printed summary.
class ForecastsFetchTaskTest < ActiveSupport::TestCase
  setup do
    Rateflow::Application.load_tasks if Rake::Task.tasks.empty?
    Rake::Task["forecasts:fetch"].reenable
  end

  # Makes ForecastsFetcher.fetch_all delegate to `fake` for the duration of
  # the block — the task must never construct a real АПЭКОН provider.
  def stubbing_fetch_all(fake)
    original = ForecastsFetcher.method(:fetch_all)
    ForecastsFetcher.define_singleton_method(:fetch_all) { |**kwargs| fake.call(**kwargs) }
    yield
  ensure
    ForecastsFetcher.define_singleton_method(:fetch_all, original)
  end

  test "without an argument the task walks all four currencies" do
    captured = nil
    fake = ->(currencies:, origin:) { captured = currencies; currencies.map { |c| { status: "fresh", currency: c } } }

    out, = capture_io do
      stubbing_fetch_all(fake) { Rake::Task["forecasts:fetch"].invoke }
    end

    assert_equal Rate::CURRENCIES, captured
    assert_equal Rate::CURRENCIES.size, out.lines.grep(/fresh/).size
  end

  test "a currency argument narrows the run, case-insensitively" do
    captured = nil
    fake = ->(currencies:, origin:) { captured = currencies; [ { status: "ok", currency: "EUR", points: 12, quote_rows: 1 } ] }

    out, = capture_io do
      stubbing_fetch_all(fake) { Rake::Task["forecasts:fetch"].invoke("eur") }
    end

    assert_equal %w[EUR], captured
    assert_match(/EUR: ok \(12 points, 1 quote rows\)/, out)
  end

  # The whole point of the journal's origin column: a run started from the
  # console must be distinguishable from someone poking the endpoint.
  test "the task marks its checks as coming from the command line" do
    captured = nil
    fake = ->(currencies:, origin:) { captured = origin; [] }

    capture_io do
      stubbing_fetch_all(fake) { Rake::Task["forecasts:fetch"].invoke("usd") }
    end

    assert_equal "task", captured
  end

  test "an unknown currency aborts before touching the site" do
    called = false

    assert_raises(SystemExit) do
      capture_io do
        stubbing_fetch_all(->(**) { called = true }) { Rake::Task["forecasts:fetch"].invoke("btc") }
      end
    end

    assert_not called
  end
end
