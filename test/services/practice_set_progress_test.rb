# frozen_string_literal: true

require "test_helper"

class PracticeSetProgressTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @user = User.create!(email_address: "progress@example.com", username: "progressuser", password: "password123")
    @set = @user.image_sets.create!(
      name: ImageSet::SAVED_FOR_PRACTICE_NAME,
      visibility: "private",
      map_style: "outdoor-v2"
    )
    @first = Image.create!(url: "https://example.com/one.jpg", latitude: 1, longitude: 1, title: "One")
    @second = Image.create!(url: "https://example.com/two.jpg", latitude: 2, longitude: 2, title: "Two")
    @set.image_set_items.create!(image: @first, latitude: @first.latitude, longitude: @first.longitude)
    @set.image_set_items.create!(image: @second, latitude: @second.latitude, longitude: @second.longitude)
    @session = {}
  end

  test "start shuffles located image ids" do
    progress = PracticeSetProgress.start(@session, @set)

    assert_equal 2, progress.total
    assert_equal @set.id, progress.set_id
    assert_equal 2, progress.remaining.size
  end

  test "complete removes image and finishes set" do
    progress = PracticeSetProgress.start(@session, @set)
    first_id = progress.current_image_id

    progress.complete!(first_id)
    assert_equal 1, progress.remaining.size
    assert_not progress.finished?

    progress.complete!(progress.current_image_id)
    assert progress.finished?
  end
end
