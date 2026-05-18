require "test_helper"

class AiGenerationJobTest < ActiveJob::TestCase
  setup do
    @user = users(:alice)
  end

  test "missing generation_id is a no-op (job does not raise)" do
    assert_nothing_raised { AiGenerationJob.perform_now(-1) }
  end

  test "pipeline failures get captured as status=failed with sanitized error" do
    gen = AiGeneration.create!(user: @user, status: "pending", user_message: "volcanoes")

    # Stub the pipeline to raise so we exercise the rescue branch.
    original = AiGenerationPipeline.instance_method(:run)
    AiGenerationPipeline.define_method(:run) { raise StandardError, "boom" }
    begin
      assert_raises(StandardError) { AiGenerationJob.perform_now(gen.id) }
    ensure
      AiGenerationPipeline.define_method(:run, original)
    end

    gen.reload
    assert_equal "failed", gen.status
    assert_match(/boom/, gen.error)
    assert_nil gen.phase
  end
end
