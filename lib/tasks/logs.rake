namespace :logs do
  desc "Delete fetch logs older than N days (default 90), scheduled-check records " \
       "older than 30 days and internal forecast snapshots older than a year; " \
       "АПЭКОН snapshots are never touched"
  task :prune, [ :days ] => :environment do |_, args|
    days = (args[:days] || LogsPruner::DEFAULT_DAYS).to_i
    removed = LogsPruner.new(days: days).call
    puts "logs:prune removed #{removed[:fetch_logs]} fetch logs older than #{days} days, " \
         "#{removed[:refresh_checks]} refresh checks older than #{LogsPruner::REFRESH_CHECK_DAYS} days " \
         "and #{removed[:internal_runs]} internal snapshots older than a year"
  end
end
