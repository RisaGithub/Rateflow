namespace :forecasts do
  desc "Replay the internal forecast daily over the last N days of CBR facts (default 180, idempotent)"
  task :backtest, [ :days ] => :environment do |_task, args|
    days = (args[:days] || InternalForecastBacktest::DAYS).to_i
    created = InternalForecastBacktest.new(from: days.days.ago.to_date).call
    total = ForecastRun.where(provider: "internal").count
    puts "forecasts:backtest created #{created} snapshots over #{days} days (#{total} internal snapshots in db)"
  end
end
