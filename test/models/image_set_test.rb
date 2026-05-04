require "test_helper"

class ImageSetTest < ActiveSupport::TestCase
  test "default set exists and is system default" do
    default = ImageSet.default
    assert default.present?
    assert default.is_system_default?
    assert_nil default.user_id
  end

  test "only one system default allowed" do
    duplicate = ImageSet.new(name: "Another Default", visibility: "public", is_system_default: true)
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:base], "a system default set already exists"
  end

  test "system default cannot have a user" do
    set = ImageSet.new(name: "Bad", visibility: "public", is_system_default: true, user: users(:alice))
    assert_not set.valid?
    assert_includes set.errors[:user], "must be blank for system default set"
  end

  test "user set requires a name" do
    set = users(:alice).image_sets.new(visibility: "private")
    assert_not set.valid?
    assert_includes set.errors[:name], "can't be blank"
  end

  test "visibility must be private or public" do
    set = users(:alice).image_sets.new(name: "Test", visibility: "secret")
    assert_not set.valid?
  end

  test "owned_by? returns true for owner" do
    set = image_sets(:alice_private)
    assert set.owned_by?(users(:alice))
    assert_not set.owned_by?(users(:bob))
  end

  test "playable_by? returns true for system default set regardless of user" do
    default = image_sets(:default)
    assert default.playable_by?(users(:alice))
    assert default.playable_by?(users(:bob))
  end

  test "playable_by? returns true for public set" do
    set = image_sets(:alice_public)
    assert set.playable_by?(users(:bob))
  end

  test "playable_by? returns false for private set owned by someone else" do
    set = image_sets(:alice_private)
    assert_not set.playable_by?(users(:bob))
  end
end
