# frozen_string_literal: true

require "test_helper"

class AiHintsBackfillTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @tier = 1
    @previous_scope = ENV["SCOPE"]
    ENV.delete("SCOPE")
  end

  teardown do
    if @previous_scope.nil?
      ENV.delete("SCOPE")
    else
      ENV["SCOPE"] = @previous_scope
    end
  end

  test "run raises Disabled when Gemini is off" do
    with_ai_hints_config(enabled: false) do
      assert_raises(AiHintsBackfill::Disabled) do
        AiHintsBackfill.run(tier: @tier, limit: 1, sleep_seconds: 0)
      end
    end
  end

  test "run enqueues jobs for images without hints and skips ready and pending" do
    with_ai_hints_config(enabled: true) do
      tier = 3
      ready_image = images(:three)
      pending_image = images(:four)
      failed_image = images(:five)
      fresh_image = images(:two)

      ImageAiHint.create!(
        image: ready_image,
        tier: tier,
        status: "ready",
        body: "Done",
        prompt_version: ImageAiHint::PROMPT_VERSION
      )
      ImageAiHint.create!(image: pending_image, tier: tier, status: "pending")
      ImageAiHint.create!(
        image: failed_image,
        tier: tier,
        status: "failed",
        error_message: "old failure"
      )

      assert_enqueued_jobs 3, only: GenerateAiHintJob do
        result = AiHintsBackfill.run(tier: tier, limit: nil, sleep_seconds: 0)
        assert_equal 3, result.enqueued
        assert_equal 2, result.skipped
      end

      assert_enqueued_with(job: GenerateAiHintJob, args: [ failed_image.id, tier ])
      assert_enqueued_with(job: GenerateAiHintJob, args: [ fresh_image.id, tier ])
    end
  end

  test "run respects limit" do
    with_ai_hints_config(enabled: true) do
      result = AiHintsBackfill.run(tier: @tier, limit: 1, sleep_seconds: 0)
      assert_equal 1, result.enqueued + result.skipped
    end
  end

  test "run re-enqueues when ready hint has stale prompt_version" do
    with_ai_hints_config(enabled: true) do
      tier = 3
      stale = ImageAiHint.create!(
        image: images(:three),
        tier: tier,
        status: "ready",
        body: "Old prompt",
        prompt_version: ImageAiHint::PROMPT_VERSION - 1
      )

      assert_enqueued_with(job: GenerateAiHintJob, args: [ stale.image_id, tier ]) do
        AiHintsBackfill.run(tier: tier, limit: nil, sleep_seconds: 0)
      end
    end
  end

  test "stats returns counts per tier and status" do
    stats = AiHintsBackfill.stats
    assert_equal ImageAiHint::TIERS.to_a, stats.keys

    ImageAiHint::TIERS.each do |tier|
      ImageAiHint::STATUSES.each do |status|
        expected = ImageAiHint.where(tier: tier, status: status).count
        assert_equal expected, stats[tier][status], "tier #{tier} #{status}"
      end
    end
  end

  private

  def with_ai_hints_config(enabled:)
    previous_enabled = ENV["AI_HINTS_ENABLED"]
    previous_key = ENV["GEMINI_API_KEY"]

    if enabled
      ENV["AI_HINTS_ENABLED"] = "true"
      ENV["GEMINI_API_KEY"] = "test-key"
    else
      ENV.delete("AI_HINTS_ENABLED")
      ENV.delete("GEMINI_API_KEY")
    end

    yield
  ensure
    if previous_enabled.nil?
      ENV.delete("AI_HINTS_ENABLED")
    else
      ENV["AI_HINTS_ENABLED"] = previous_enabled
    end

    if previous_key.nil?
      ENV.delete("GEMINI_API_KEY")
    else
      ENV["GEMINI_API_KEY"] = previous_key
    end
  end
end
