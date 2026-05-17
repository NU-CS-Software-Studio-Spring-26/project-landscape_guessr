# frozen_string_literal: true

require "test_helper"

class GeminiHintGeneratorTest < ActiveSupport::TestCase
  self.fixture_table_names = []

  setup do
    @image = Image.create!(
      url: "https://example.com/photo.jpg",
      latitude: 46.8182,
      longitude: 8.2275,
      title: "Golden Roof Landmark"
    )
    @location = HintLocationContext::Location.new(
      country: "Switzerland",
      country_code: "CH",
      region: "Bern",
      city: "Interlaken",
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

  test "generate sends text-only prompt with location data and no image" do
    stub_request(:post, %r{\Ahttps://generativelanguage\.googleapis\.com/v1beta/models/.+:generateContent})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          candidates: [
            { content: { parts: [ { text: "Think of a famous alpine storybook girl." } ] } }
          ]
        }.to_json
      )

    hint = GeminiHintGenerator.generate(
      image: @image,
      tier: 2,
      location: @location
    )

    assert_equal "Think of a famous alpine storybook girl.", hint
    assert_requested :post, %r{generativelanguage\.googleapis\.com}, times: 1 do |request|
      body = request.body
      refute_includes body, @image.title
      refute_includes body, "Golden"
      refute_includes body, "inline_data"
      refute_includes body, "image/jpeg"
      assert_includes body, "text location data only"
      assert_includes body, "Country: Switzerland"
      assert_includes body, "Climate band: Northern mid-latitudes"
      assert_includes body, "cultural, historical, folklore"
      assert_includes body, "plain, simple English"
    end
  end

  test "tier 1 prompt asks for common-knowledge niche clues" do
    generator = GeminiHintGenerator.new(image: @image, tier: 1, location: @location)
    prompt = generator.send(:prompt_for_tier, 1)

    assert_includes prompt, "common knowledge"
    assert_includes prompt, "niche"
    assert_includes prompt, "not vague scenery"
    assert_includes prompt, "plain, simple English"
    refute_includes prompt, "folklore, food"
  end

  test "raises when location is missing" do
    assert_raises(GeminiHintGenerator::ApiError) do
      GeminiHintGenerator.generate(image: @image, tier: 2, location: nil)
    end
  end

  test "retries with geographic feedback when safety filter rejects leaked location" do
    requests = []
    stub_request(:post, %r{generativelanguage\.googleapis\.com})
      .to_return do |request|
        requests << request
        body = if requests.size == 1
                 { candidates: [ { content: { parts: [ { text: "Snowy peaks typical of Switzerland." } ] } } ] }
               else
                 { candidates: [ { content: { parts: [ { text: "Think of alpine timber chalets and mountain pastures." } ] } } ] }
               end
        { status: 200, headers: { "Content-Type" => "application/json" }, body: body.to_json }
      end

    hint = GeminiHintGenerator.generate(image: @image, tier: 2, location: @location)

    assert_equal "Think of alpine timber chalets and mountain pastures.", hint
    assert_equal 2, requests.size
    assert_includes requests.last.body, "Revision required"
    assert_includes requests.last.body, "continent, country, region"
  end

  test "raises when safety filter still rejects after max retries" do
    stub_request(:post, %r{generativelanguage\.googleapis\.com})
      .to_return(
        status: 200,
        headers: { "Content-Type" => "application/json" },
        body: {
          candidates: [
            { content: { parts: [ { text: "Snowy peaks typical of Switzerland." } ] } }
          ]
        }.to_json
      )

    assert_raises(GeminiHintGenerator::ApiError, match: /safety filter after/) do
      GeminiHintGenerator.generate(image: @image, tier: 2, location: @location)
    end

    assert_requested :post, %r{generativelanguage\.googleapis\.com}, times: GeminiHintGenerator::MAX_SAFETY_RETRIES
  end

  test "raises retryable error on HTTP 429" do
    stub_request(:post, %r{generativelanguage\.googleapis\.com})
      .to_return(status: 429, body: "rate limited")

    assert_raises(GeminiHintGenerator::RetryableError) do
      GeminiHintGenerator.generate(image: @image, tier: 2, location: @location)
    end
  end
end
