namespace :forecasts do
  desc "Replay the internal forecast weekly over the last two years of CBR facts (idempotent)"
  task backtest: :environment do
    created = InternalForecastBacktest.new.call
    total = ForecastRun.where(provider: "internal").count
    puts "forecasts:backtest created #{created} snapshots (#{total} internal snapshots in db)"
  end
end
