require "test_helper"

class AiGenerationTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
  end

  test "JSON accessors degrade to empty values on blank or garbage input" do
    gen = AiGeneration.new(user: @user, conversation_json: nil, result_json: "{not json",
                            preview_json: "")
    assert_equal [], gen.conversation
    assert_nil   gen.result
    assert_equal [], gen.preview
  end

  test "conversation round-trips with symbolized keys" do
    gen = AiGeneration.create!(
      user: @user,
      conversation_json: [ { role: "user", text: "hi" } ].to_json
    )
    assert_equal [ { role: "user", text: "hi" } ], gen.conversation
  end

  test "in_progress? is true for fresh pending and running records" do
    gen = AiGeneration.create!(user: @user, status: "pending")
    assert gen.in_progress?
    gen.update!(status: "running")
    assert gen.in_progress?
  end

  test "in_progress? is false for completed and failed" do
    gen = AiGeneration.create!(user: @user, status: "completed")
    refute gen.in_progress?
    gen.update!(status: "failed")
    refute gen.in_progress?
  end

  test "stale? flips running records whose updated_at exceeds STALE_AFTER" do
    gen = AiGeneration.create!(user: @user, status: "running")
    # touch updated_at back in time, bypassing AR's auto-touching
    gen.update_columns(updated_at: 10.minutes.ago)
    assert gen.stale?
    refute gen.in_progress?
  end

  test "status inclusion validation rejects garbage" do
    gen = AiGeneration.new(user: @user, status: "garbage")
    refute gen.valid?
    assert_includes gen.errors[:status].join, "not included"
  end
end
