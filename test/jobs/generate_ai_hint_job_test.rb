# frozen_string_literal: true

require "test_helper"

class GenerateAiHintJobTest < ActiveJob::TestCase
  self.fixture_table_names = []

  setup do
    @image = Image.create!(
      url: "https://example.com/job-hint.jpg",
      latitude: 47.2692,
      longitude: 11.4041,
      title: "Secret Landmark Name"
    )
    @location = HintLocationContext::Location.new(
      country: "Austria",
      country_code: "AT",
      region: "Tyrol",
      city: "Innsbruck",
      continent: "Europe",
      latitude_band: "Northern mid-latitudes"
    )
    @previous_api_key = ENV["GEMINI_API_KEY"]
    @previous_enabled = ENV["AI_HINTS_ENABLED"]
    ENV["GEMINI_API_KEY"] = "test-gemini-key"
    ENV["AI_HINTS_ENABLED"] = "true"
  end

  teardown do
    ENV["GEMINI_API_KEY"] = @previous_api_key
    ENV["AI_HINTS_ENABLED"] = @previous_enabled
  end

  test "perform_now creates ready hint when dependencies are stubbed" do
    location = @location
    stub_class_method(HintLocationContext, :for_image, ->(*_args) { location }) do
      stub_class_method(GeminiHintGenerator, :generate, ->(*_args) { "Steep alpine meadows with timber chalets." }) do
        assert_difference -> { ImageAiHint.count }, 1 do
          GenerateAiHintJob.perform_now(@image.id, 1)
        end
      end
    end

    hint = ImageAiHint.find_by!(image: @image, tier: 1)
    assert_equal "ready", hint.status
    assert_equal "Steep alpine meadows with timber chalets.", hint.body
    assert_equal GeminiConfig.model, hint.model
    assert_equal GeminiHintGenerator::PROMPT_VERSION, hint.prompt_version
    assert_nil hint.error_message
  end

  test "skips when already ready at current prompt version" do
    ImageAiHint.create!(
      image: @image,
      tier: 1,
      status: "ready",
      body: "Existing hint",
      model: GeminiConfig.model,
      prompt_version: GeminiHintGenerator::PROMPT_VERSION
    )

    called = false
    stub_class_method(GeminiHintGenerator, :generate, ->(*_args) { called = true }) do
      assert_no_difference -> { ImageAiHint.count } do
        GenerateAiHintJob.perform_now(@image.id, 1)
      end
    end

    assert_not called
    assert_equal "Existing hint", ImageAiHint.find_by!(image: @image, tier: 1).body
  end

  test "marks failed when generator cannot produce a safe hint" do
    location = @location
    stub_class_method(HintLocationContext, :for_image, ->(*_args) { location }) do
      stub_class_method(GeminiHintGenerator, :generate, ->(*_args) { raise GeminiHintGenerator::ApiError, "Hint failed safety filter after 3 attempts" }) do
        GenerateAiHintJob.perform_now(@image.id, 2)
      end
    end

    hint = ImageAiHint.find_by!(image: @image, tier: 2)
    assert_equal "failed", hint.status
    assert_match(/safety filter/, hint.error_message)
  end

  test "marks failed when image has no coordinates" do
    image = Image.create!(url: "https://example.com/photo.jpg", title: "No coords", latitude: nil, longitude: nil)

    GenerateAiHintJob.perform_now(image.id, 1)

    hint = ImageAiHint.find_by!(image: image, tier: 1)
    assert_equal "failed", hint.status
    assert_match(/no coordinates/i, hint.error_message)
  end

  test "marks failed when coordinates cannot be geocoded" do
    stub_class_method(HintLocationContext, :for_image, ->(*_args) { nil }) do
      GenerateAiHintJob.perform_now(@image.id, 1)
    end

    hint = ImageAiHint.find_by!(image: @image, tier: 1)
    assert_equal "failed", hint.status
    assert_match(/geocode/i, hint.error_message)
  end
end
