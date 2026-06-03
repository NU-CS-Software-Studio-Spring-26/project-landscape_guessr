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

  # --- geographic extent + per-set score scaling ---

  test "geo_bbox spans the set's item coordinates" do
    bbox = image_sets(:alice_private).geo_bbox
    assert_in_delta 1.0, bbox[:min_lat], 0.001
    assert_in_delta 5.0, bbox[:max_lat], 0.001
    assert_in_delta 2.0, bbox[:min_lng], 0.001
    assert_in_delta 6.0, bbox[:max_lng], 0.001
  end

  test "scoring_decay_km scales below the world default for a small set" do
    decay = image_sets(:alice_private).scoring_decay_km
    assert decay.positive?
    assert decay < Game::GEOGUESSR_DECAY_KM
    assert decay >= ImageSet::SCORING_DECAY_MIN_KM
  end

  test "scoring_decay_km falls back to the world default when items share one point" do
    # The default set's items all sit at (9.99, 9.99) — zero spread.
    assert_equal Game::GEOGUESSR_DECAY_KM, image_sets(:default).scoring_decay_km
  end

  # --- popularity ordering ---

  test "by_popularity orders most-played sets first" do
    a = ImageSet.create!(name: "Pop A", visibility: "public")
    b = ImageSet.create!(name: "Pop B", visibility: "public")
    users(:alice).games.create!(status: "completed", image_set: a, completed_at: Time.current, score: 1)

    ordered = ImageSet.where(id: [ a.id, b.id ]).by_popularity
    assert_equal [ a.id, b.id ], ordered.map(&:id)
  end

  # --- defensive: public visibility is gated ---

  test "non-admin cannot make their custom set public" do
    set = users(:alice).image_sets.new(name: "Alice Public", visibility: "public")
    assert_not set.valid?
    assert_includes set.errors[:visibility], "can only be set to public by an admin or for AI-generated sets"
  end

  test "non-admin cannot flip an existing private set to public" do
    set = image_sets(:alice_private)
    set.visibility = "public"
    assert_not set.valid?
  end

  test "admin can make their custom set public" do
    set = users(:admin).image_sets.new(name: "Admin Public", visibility: "public")
    assert set.valid?, set.errors.full_messages.to_sentence
  end

  test "AI-generated custom set may be public" do
    set = users(:alice).image_sets.new(name: "AI Public", visibility: "public", ai_query: "?item wdt:P31 wd:Q8072 .")
    assert set.valid?, set.errors.full_messages.to_sentence
  end

  test "ownerless set may be public" do
    set = ImageSet.new(name: "Ownerless Public", visibility: "public")
    assert set.valid?, set.errors.full_messages.to_sentence
  end

  test "already-public set stays valid when edited for unrelated reasons" do
    set = image_sets(:alice_public)
    set.name = "Renamed Public"
    assert set.valid?, set.errors.full_messages.to_sentence
  end
end
