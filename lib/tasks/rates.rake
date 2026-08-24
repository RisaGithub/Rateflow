namespace :rates do
  desc "Fetch recent rates from all three providers and upsert them"
  task fetch: :environment do
    written = RatesFetcher.new.call
    latest = FetchLog.for_kind("rates").recent.limit(3)
    puts "rates:fetch wrote #{written} rows; attempts: " +
         latest.map { |l| "#{l.provider}=#{l.ok ? 'ok' : 'fail'}" }.reverse.join(", ")
  end

  desc "One-off archive load from CBR and Currency API; from defaults to 1999-01-01"
  task :backfill, [ :from ] => :environment do |_, args|
    from = args[:from] ? Date.iso8601(args[:from]) : RatesBackfill::DEFAULT_FROM
    written = RatesBackfill.new(from: from).call
    puts "rates:backfill wrote #{written} rows (#{Rate.count} total in db)"
  end
end
