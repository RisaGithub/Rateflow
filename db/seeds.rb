# Seed with real data by running the same task the daily job uses.
Rake::Task["rates:fetch"].invoke
