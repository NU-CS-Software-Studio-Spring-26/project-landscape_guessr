ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...

    # By default, treat all image URLs as reachable in test env. The
    # game/challenge create paths use ImageReachability to filter broken
    # URLs via HEAD; test fixtures use example.com placeholders that
    # would actually return 404 against a real network. Tests that want
    # to exercise the broken-URL branch can override per-test.
    setup do
      ImageReachability.singleton_class.define_method(:reachable) { |urls| urls.to_a }
    end
  end
end

class ActionDispatch::IntegrationTest
  def sign_in_as(user, password = "password123")
    post session_url, params: { login: user.email_address, password: password }
  end
end
