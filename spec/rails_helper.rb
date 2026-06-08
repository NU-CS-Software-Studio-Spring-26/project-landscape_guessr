require "spec_helper"

ENV["RAILS_ENV"] ||= "test"
# Same placeholder as Minitest test_helper — lets AiImageSetGenerator initialize
# without a real key; HTTP layer is stubbed via WebMock.
ENV["GEMINI_API_KEY"] ||= "test-placeholder"

require_relative "../config/environment"
abort("Running in production mode!") if Rails.env.production?
require "rspec/rails"
require "webmock/rspec"
require "factory_bot_rails"
require "database_cleaner/active_record"

begin
  ActiveRecord::Migration.maintain_test_schema!
rescue ActiveRecord::PendingMigrationError => e
  abort e.to_s.strip
end

RSpec.configure do |config|
  # FactoryBot DSL available in all specs (create, build, build_stubbed, etc.)
  config.include FactoryBot::Syntax::Methods

  # Use transactional fixtures — each example runs inside a transaction that is
  # rolled back at the end. This is faster than truncation and is the Rails default.
  config.use_transactional_fixtures = true

  # Infer spec type from directory — models/, requests/, jobs/, services/ etc.
  config.infer_spec_type_from_file_location!

  config.filter_rails_from_backtrace!

  # Block real network in tests; individual specs stub what they need.
  WebMock.disable_net_connect!(allow_localhost: true)

  # Treat all image URLs as reachable by default (mirrors test_helper.rb).
  # Specs that test broken-URL behaviour can stub ImageReachability.reachable directly.
  config.before(:each) do
    allow(ImageReachability).to receive(:reachable) { |urls| urls.to_a } if defined?(ImageReachability)
  end

  # Helper to sign in a user for request specs via the session endpoint,
  # mirroring sign_in_as in ActionDispatch::IntegrationTest.
  module RequestSpecHelpers
    def sign_in_as(user, password = "password123")
      post session_url, params: { login: user.email_address, password: password }
    end
  end

  config.include RequestSpecHelpers, type: :request
end
