namespace :rates do
  desc "Fetch recent rates from all three providers and upsert them"
  task fetch: :environment do
    written = RatesFetcher.new.call
    latest = FetchLog.recent.limit(Rate::PROVIDERS.size)
    puts "rates:fetch wrote #{written} rows; attempts: " +
         latest.map { |l| "#{l.provider}=#{l.ok ? 'ok' : 'fail'}" }.reverse.join(", ")
  end
end
