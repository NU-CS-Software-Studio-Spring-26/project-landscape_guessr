# frozen_string_literal: true

require "test_helper"

require Rails.root.join("db/migrate/20260517120000_create_image_ai_hints")

class CreateImageAiHintsMigrationTest < ActiveSupport::TestCase
  # Drops/recreates image_ai_hints; must not run beside parallel workers using fixtures.
  parallelize(workers: 1)

  self.fixture_table_names = []
  self.use_transactional_tests = false

  setup do
    @connection = ActiveRecord::Base.connection
    @migration = CreateImageAiHints.new
  end

  test "up creates table and unique index; down removes them" do
    @migration.down if @connection.table_exists?(:image_ai_hints)

    assert_not @connection.table_exists?(:image_ai_hints)

    @migration.up

    assert @connection.table_exists?(:image_ai_hints)
    assert @connection.index_exists?(
      :image_ai_hints,
      [ :image_id, :tier ],
      unique: true,
      name: "index_image_ai_hints_on_image_id_and_tier"
    )

    @migration.down

    assert_not @connection.table_exists?(:image_ai_hints)
    assert_not @connection.index_exists?(
      :image_ai_hints,
      [ :image_id, :tier ],
      name: "index_image_ai_hints_on_image_id_and_tier"
    )
  ensure
    @migration.up unless @connection.table_exists?(:image_ai_hints)
  end
end
