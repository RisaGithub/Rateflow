#!/usr/bin/env bash
# Render build command: install gems and precompile assets.
# Migrations run on start (see README), so a deploy never serves an unmigrated schema.
set -o errexit

bundle install
bundle exec rails assets:precompile
