require "test_helper"

class ImageSetItemTest < ActiveSupport::TestCase
  test "image cannot appear twice in the same set" do
    existing = image_set_items(:default_one)
    duplicate = ImageSetItem.new(
      image_set: existing.image_set,
      image:     existing.image,
      latitude:  1.0,
      longitude: 1.0
    )
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:image_id], "already in this set"
  end

  test "answer_lat falls back to image when item latitude is nil" do
    item = image_set_items(:default_one)
    item.latitude = nil
    assert_equal item.image.latitude.to_f, item.answer_lat
  end

  test "answer_lat uses stored latitude when present" do
    item = image_set_items(:alice_private_one)
    assert_equal 1.0, item.answer_lat
  end
end
