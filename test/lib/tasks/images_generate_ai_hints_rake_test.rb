# frozen_string_literal: true

require "test_helper"
require "rake"

class ImagesGenerateAiHintsRakeTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  setup do
    @previous_scope = ENV["SCOPE"]
    ENV.delete("SCOPE")
    Rails.application.load_tasks if Rake::Task.tasks.empty?
    @task = Rake::Task["images:generate_ai_hints"]
    @task.reenable
  end

  teardown do
    @task.reenable
    if @previous_scope.nil?
      ENV.delete("SCOPE")
    else
      ENV["SCOPE"] = @previous_scope
    end
  end

  test "rake task aborts when Gemini is disabled" do
    with_ai_hints_config(enabled: false) do
      assert_output(nil, /disabled/i) do
        assert_raises(SystemExit) { @task.invoke("1", "1", "0") }
      end
    end
  end

  test "rake task enqueues with stubbed config" do
    with_ai_hints_config(enabled: true) do
      ImageAiHint.where(tier: 3).delete_all
      assert_enqueued_jobs 1, only: GenerateAiHintJob do
        assert_output(/enqueued 1, skipped/) { @task.invoke("3", "1", "0") }
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
