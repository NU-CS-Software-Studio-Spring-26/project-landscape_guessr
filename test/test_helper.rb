ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"
require "active_record/connection_adapters/postgresql_adapter"
require "webmock/minitest"

# PostgreSQL fixture loading normally DISABLE TRIGGER ALL (superuser) then DELETE.
# Without superuser, use TRUNCATE CASCADE before inserting fixture rows.
module PostgreSQLNonSuperuserFixtureLoading
  def insert_fixtures_set(fixture_set, tables_to_delete = [])
    tables_to_clear = tables_to_delete.presence || fixture_set.keys
    quoted = tables_to_clear.map { |table| quote_table_name(table) }.join(", ")

    transaction(requires_new: true) do
      execute("TRUNCATE #{quoted} RESTART IDENTITY CASCADE")
      execute_batch(build_fixture_statements(fixture_set), "Fixtures Load")
    end
  end
end

ActiveRecord::ConnectionAdapters::PostgreSQLAdapter.prepend(PostgreSQLNonSuperuserFixtureLoading)

WebMock.disable_net_connect!(allow_localhost: true)

def stub_class_method(klass, method_name, implementation)
  original = klass.method(method_name)
  klass.define_singleton_method(method_name, implementation)
  yield
ensure
  klass.define_singleton_method(method_name, original)
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # FK-safe order without .sort (Rails' fixtures helper sorts alphabetically,
    # which inserts game_images before games when RI cannot be disabled).
    FIXTURE_TABLE_NAMES = %w[
      users image_sets images image_set_items
      games game_images guesses image_ai_hints
    ].freeze
    self.fixture_table_names = FIXTURE_TABLE_NAMES.dup
    setup_fixture_accessors(FIXTURE_TABLE_NAMES)

    # Add more helper methods to be used by all tests here...
  end
end

class ActionDispatch::IntegrationTest
  def sign_in_as(user, password = "password123")
    post session_url, params: { login: user.email_address, password: password }
  end
end
