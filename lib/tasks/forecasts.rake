namespace :forecasts do
  desc "Fetch АПЭКОН forecasts (today's quotes included): one currency, or all four with the 10s crawl pause"
  task :fetch, [ :currency ] => :environment do |_task, args|
    currencies = args[:currency] ? [ args[:currency].upcase ] : Rate::CURRENCIES
    unless (currencies - Rate::CURRENCIES).empty?
      abort "forecasts:fetch: unknown currency #{args[:currency].inspect} (expected one of #{Rate::CURRENCIES.join(', ')})"
    end

    ForecastsFetcher.fetch_all(currencies: currencies).each do |result|
      detail = case result[:status]
      when "ok"    then "#{result[:points]} points, #{result[:quote_rows]} quote rows"
      when "fresh" then "skipped, updated less than a day ago"
      else result[:error]
      end
      puts "forecasts:fetch #{result[:currency]}: #{result[:status]} (#{detail})"
    end
  end

  desc "Replay the internal forecast daily over the last N days of CBR facts (default 180, idempotent)"
  task :backtest, [ :days ] => :environment do |_task, args|
    days = (args[:days] || InternalForecastBacktest::DAYS).to_i
    created = InternalForecastBacktest.new(from: days.days.ago.to_date).call
    total = ForecastRun.where(provider: "internal").count
    puts "forecasts:backtest created #{created} snapshots over #{days} days (#{total} internal snapshots in db)"
  end
end
