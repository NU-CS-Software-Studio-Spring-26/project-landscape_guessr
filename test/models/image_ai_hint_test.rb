require "test_helper"

class ImageAiHintTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @image = Image.create!(
      url: "https://example.com/hint-test.jpg",
      latitude: 47.0,
      longitude: 11.0,
      title: "Hint test image"
    )
    @other_image = Image.create!(
      url: "https://example.com/hint-test-2.jpg",
      latitude: 48.0,
      longitude: 12.0,
      title: "Other hint test image"
    )
    @ready_hint = ImageAiHint.create!(
      image: @image,
      tier: 1,
      status: "ready",
      body: "Alpine terrain",
      model: "gemini-2.5-flash-lite"
    )
    @pending_hint = ImageAiHint.create!(image: @image, tier: 2, status: "pending")
    @failed_hint = ImageAiHint.create!(
      image: @other_image,
      tier: 1,
      status: "failed",
      error_message: "API timeout"
    )
  end

  test "valid hint with required attributes" do
    hint = ImageAiHint.new(image: @other_image, tier: 3, status: "ready", body: "Coastal cliffs")
    assert hint.valid?
    assert hint.save
  end

  test "tier must be 1, 2, or 3" do
    hint = ImageAiHint.new(image: @other_image, tier: 4, status: "pending")
    assert_not hint.valid?
    assert_includes hint.errors[:tier], "is not included in the list"
  end

  test "status must be pending, ready, or failed" do
    hint = ImageAiHint.new(image: @other_image, tier: 3, status: "unknown")
    assert_not hint.valid?
    assert_includes hint.errors[:status], "is not included in the list"
  end

  test "tier is unique per image at model level" do
    duplicate = ImageAiHint.new(image: @image, tier: @ready_hint.tier, status: "pending")
    assert_not duplicate.valid?
    assert_includes duplicate.errors[:tier], "has already been taken"
  end

  test "duplicate image_id and tier raises at database level" do
    duplicate = ImageAiHint.new(
      image_id: @ready_hint.image_id,
      tier: @ready_hint.tier,
      status: "ready",
      body: "Duplicate"
    )
    assert_raises(ActiveRecord::RecordNotUnique) { duplicate.save!(validate: false) }
  end

  test "scopes filter by status and tier" do
    assert_includes ImageAiHint.ready, @ready_hint
    assert_includes ImageAiHint.pending, @pending_hint
    assert_includes ImageAiHint.failed, @failed_hint
    assert_equal [ @ready_hint ], ImageAiHint.for_tier(1).where(image: @image).to_a
  end

  test "create with ready body matches acceptance example" do
    hint = ImageAiHint.create!(
      image: @other_image,
      tier: 3,
      status: "ready",
      body: "Alpine terrain"
    )
    assert_equal "ready", hint.status
    assert_equal "Alpine terrain", hint.body
  end
end
