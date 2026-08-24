#!/usr/bin/env bash
# Render build command: install gems, precompile assets, migrate the database.
# errexit makes the deploy fail on the first broken step instead of shipping it;
# a failed build keeps the previous version live.
set -o errexit

bundle install
bundle exec rails assets:precompile
bundle exec rails db:migrate
