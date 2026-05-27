# frozen_string_literal: true

require "test_helper"

class PracticeSetProgressTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @user = User.create!(email_address: "progress@example.com", username: "progressuser", password: "password123")
    @set = @user.image_sets.create!(
      name: ImageSet::SAVED_FOR_PRACTICE_NAME,
      visibility: "private",
      map_style: "outdoor-v2",
      system_managed: true
    )
    @first = Image.create!(url: "https://example.com/one.jpg", latitude: 1, longitude: 1, title: "One")
    @second = Image.create!(url: "https://example.com/two.jpg", latitude: 2, longitude: 2, title: "Two")
    @set.image_set_items.create!(image: @first, latitude: @first.latitude, longitude: @first.longitude)
    @set.image_set_items.create!(image: @second, latitude: @second.latitude, longitude: @second.longitude)
    @session = {}
  end

  test "start records total and starts with no completed images" do
    all_ids = PracticeSetProgress.located_image_ids_for(@set)
    progress = PracticeSetProgress.start(@session, @set, all_ids: all_ids)

    assert_equal 2, progress.total
    assert_equal @set.id, progress.set_id
    assert_equal 2, progress.remaining(all_ids: all_ids).size
  end

  test "complete removes image from remaining and finishes set" do
    all_ids = PracticeSetProgress.located_image_ids_for(@set)
    progress = PracticeSetProgress.start(@session, @set, all_ids: all_ids)
    first_id = progress.current_image_id(all_ids: all_ids)

    progress.complete!(first_id)
    assert_equal 1, progress.remaining(all_ids: all_ids).size
    assert_not progress.finished?

    progress.complete!(progress.current_image_id(all_ids: all_ids))
    assert progress.finished?
  end

  test "session stores completed ids not remaining ids" do
    all_ids = PracticeSetProgress.located_image_ids_for(@set)
    progress = PracticeSetProgress.start(@session, @set, all_ids: all_ids)

    assert @session[:practice_set_progress].key?("completed_ids"),
           "session must store completed_ids to avoid cookie overflow"
    assert_not @session[:practice_set_progress].key?("remaining"),
               "session must not store remaining ids (cookie overflow risk)"
    assert_equal [], @session[:practice_set_progress]["completed_ids"]
  end

  test "completing an image persists it in completed ids" do
    all_ids = PracticeSetProgress.located_image_ids_for(@set)
    progress = PracticeSetProgress.start(@session, @set, all_ids: all_ids)
    first_id = progress.current_image_id(all_ids: all_ids)

    progress.complete!(first_id)

    assert_includes @session[:practice_set_progress]["completed_ids"], first_id
    assert_equal 1, @session[:practice_set_progress]["completed_ids"].size
  end
end
