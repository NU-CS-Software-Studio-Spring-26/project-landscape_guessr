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

  test "tag_list assigns tags and normalizes slugs" do
    set = users(:alice).image_sets.create!(name: "Tagged", visibility: "private", tag_list: "Forest,  alpine , forest")
    assert_equal %w[Alpine Forest], set.tags.order(:name).pluck(:name)
    assert_equal "alpine", set.tags.find_by(name: "Alpine")&.slug
  end

  test "tag_list strips leading and trailing whitespace before creating tags" do
    set = users(:alice).image_sets.create!(name: "Trimmed Tags", visibility: "private", tag_list: "  Mixed Case Tag  ")

    assert_equal [ "Mixed Case Tag" ], set.tags.pluck(:name)
    assert_nil Tag.find_by(name: "  Mixed Case Tag  ")
  end

  test "tagged_with finds sets by tag slug or name" do
    assert_includes ImageSet.tagged_with("forest"), image_sets(:alice_private)
    assert_includes ImageSet.tagged_with("  FOREST  "), image_sets(:alice_private)
    assert_not_includes ImageSet.tagged_with("  forest  "), image_sets(:alice_public)
  end

  test "tagged_with can match exact tag name casing" do
    assert_includes ImageSet.tagged_with("  Forest  ", case_sensitive: true), image_sets(:alice_private)
    assert_not_includes ImageSet.tagged_with("  forest  ", case_sensitive: true), image_sets(:alice_private)
  end

  test "tagged_with any returns sets matching at least one tag" do
    matches = ImageSet.tagged_with(%w[forest alpine], match: "any")
    assert_includes matches, image_sets(:alice_private)
    assert_includes matches, image_sets(:alice_public)
  end

  test "tagged_with all returns only sets with every tag" do
    matches = ImageSet.tagged_with(%w[forest alpine], match: "all")
    assert_includes matches, image_sets(:alice_private)
    assert_not_includes matches, image_sets(:alice_public)
  end

  test "tagged_with all exact names requires each requested casing" do
    matches = ImageSet.tagged_with([ "Forest", "Alpine" ], match: "all", case_sensitive: true)
    assert_includes matches, image_sets(:alice_private)

    mismatched = ImageSet.tagged_with([ "Forest", "alpine" ], match: "all", case_sensitive: true)
    assert_not_includes mismatched, image_sets(:alice_private)
  end

  test "normalize_tag_slugs deduplicates and parameterizes" do
    assert_equal %w[forest alpine], ImageSet.normalize_tag_slugs([ "Forest", "alpine", "forest", "" ])
  end

  test "normalize_tag_names keeps exact casing" do
    assert_equal [ "Forest", "forest" ], ImageSet.normalize_tag_names([ " Forest ", "forest", "" ])
  end
end
