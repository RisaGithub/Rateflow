namespace :rates do
  desc "Fetch the last 90 days of rates from CBR (fallback: ER-API) and upsert them"
  task fetch: :environment do
    written = RatesFetcher.new(days: 90).call
    latest = FetchLog.recent.limit(Rate::CURRENCIES.size + 1)
    puts "rates:fetch wrote #{written} rows; attempts: " +
         latest.map { |l| "#{l.provider}=#{l.ok ? 'ok' : 'fail'}" }.reverse.join(", ")
  end
end
