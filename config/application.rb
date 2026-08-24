require_relative "boot"

require "rails"
# Pick the frameworks you want:
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
# require "active_storage/engine"
require "action_controller/railtie"
# require "action_mailer/railtie"
# require "action_mailbox/engine"
# require "action_text/engine"
require "action_view/railtie"
# require "action_cable/engine"
require "rails/test_unit/railtie"

# Require the gems listed in Gemfile, including any gems
# you've limited to :test, :development, or :production.
Bundler.require(*Rails.groups)

# Local convenience without a dotenv gem: in development and test, read a
# git-ignored .env (KEY=value per line, # for comments) into ENV. Real
# environments set variables through the host, so ENV always wins over the file.
if %w[development test].include?(ENV.fetch("RAILS_ENV", "development"))
  env_file = File.expand_path("../.env", __dir__)
  if File.exist?(env_file)
    File.foreach(env_file) do |line|
      next unless line =~ /\A([A-Z0-9_]+)=(.*)\z/m

      ENV[$1] ||= $2.strip.delete_prefix('"').delete_suffix('"')
    end
  end
end

module Rateflow
  class Application < Rails::Application
    # Initialize configuration defaults for originally generated Rails version.
    config.load_defaults 8.1

    # Please, add to the `ignore` list any other `lib` subdirectories that do
    # not contain `.rb` files, or that should not be reloaded or eager loaded.
    # Common ones are `templates`, `generators`, or `middleware`, for example.
    config.autoload_lib(ignore: %w[assets tasks])

    # CBR rates live in Moscow time; keeping the app clock there means
    # Date.current matches the date the rates are published under.
    config.time_zone = "Europe/Moscow"

    # Configuration for the application, engines, and railties goes here.
    #
    # These settings can be overridden in specific environments using the files
    # in config/environments, which are processed later.
    #
    # config.eager_load_paths << Rails.root.join("extras")

    # Don't generate system test files.
    config.generators.system_tests = nil
  end
end
