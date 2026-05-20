require "test_helper"

class AiImageSetGeneratorTest < ActiveSupport::TestCase
  # No live network — we stub Gemini at the HTTP layer so the test
  # exercises request shaping, the tool-call loop, validation, and
  # error paths without burning quota.

  test "raises if API key missing" do
    assert_raises(AiImageSetGenerator::Error) do
      AiImageSetGenerator.new(api_key: nil)
    end
  end

  test "raises if conversation does not end with user turn" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    assert_raises(AiImageSetGenerator::Error) do
      gen.generate(conversation: [ { role: "model", text: "hi" } ])
    end
  end

  test "rejects unknown model" do
    assert_raises(AiImageSetGenerator::Error) do
      AiImageSetGenerator.new(api_key: "stub", model: :ultra)
    end
  end

  test "single-shot submit_answer (no tool calls)" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    args = {
      sparql_pattern: "?item wdt:P31 wd:Q8072 .",
      set_name:       "Volcanoes",
      explanation:    "Finding volcanoes.",
      cannot_answer:  false
    }
    queue_gemini_responses([ submit_answer_envelope(args) ]) do
      r = gen.generate(conversation: [ { role: "user", text: "volcanoes" } ])
      assert_equal "Volcanoes", r[:set_name]
      refute r[:cannot_answer]
    end
  end

  test "search_wikidata then submit_answer flow" do
    gen = AiImageSetGenerator.new(api_key: "stub")

    # Pre-stub the Wikidata search class method so the tool-execution
    # step is deterministic (the real service is tested separately).
    stub_class_method(WikidataEntitySearch, :search,
                       [ { qid: "Q8072", label: "volcano", description: "type of mountain" } ]) do
      queue_gemini_responses([
        function_call_envelope("search_wikidata", { query: "volcano" }),
        submit_answer_envelope(
          sparql_pattern: "?item wdt:P31/wdt:P279* wd:Q8072 ; wdt:P625 ?coord .",
          set_name:       "Volcanoes",
          explanation:    "Finding volcanoes.",
          cannot_answer:  false
        )
      ]) do
        r = gen.generate(conversation: [ { role: "user", text: "volcanoes" } ])
        assert_match(/Q8072/, r[:sparql_pattern])
      end
    end
  end

  test "text-only response triggers ONE retry, then fails" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    text = { candidates: [ { content: { parts: [ { text: "Sure, here is your answer" } ] } } ] }.to_json
    queue_gemini_responses([ text, text ]) do
      assert_raises(AiImageSetGenerator::InvalidResponseError) do
        gen.generate(conversation: [ { role: "user", text: "volcanoes" } ])
      end
    end
  end

  test "submit_answer with SELECT in pattern is rejected" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    args = {
      sparql_pattern: "SELECT * WHERE { ?item wdt:P31 wd:Q8072 . }",
      set_name: "X", explanation: "x", cannot_answer: false
    }
    queue_gemini_responses([ submit_answer_envelope(args) ]) do
      assert_raises(AiImageSetGenerator::InvalidResponseError) do
        gen.generate(conversation: [ { role: "user", text: "x" } ])
      end
    end
  end

  test "submit_answer with FILTER in pattern is allowed" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    args = {
      sparql_pattern: "?item wdt:P31 wd:Q46831 ; wdt:P2043 ?len ; wdt:P625 ?coord . FILTER(?len > 500)",
      set_name: "Major Mountain Ranges", explanation: "Ranges over 500 km.",
      cannot_answer: false
    }
    queue_gemini_responses([ submit_answer_envelope(args) ]) do
      r = gen.generate(conversation: [ { role: "user", text: "major mountain ranges" } ])
      assert_match(/FILTER/, r[:sparql_pattern])
    end
  end

  test "cannot_answer accepts empty pattern" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    args = {
      sparql_pattern: "",
      set_name: "Ramen Shops",
      explanation: "Wikidata doesn't list restaurants.",
      cannot_answer: true
    }
    queue_gemini_responses([ submit_answer_envelope(args) ]) do
      r = gen.generate(conversation: [ { role: "user", text: "ramen shops" } ])
      assert r[:cannot_answer]
    end
  end

  test "region_filter is assembled from flat fields when all valid" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    args = {
      sparql_pattern: "?item wdt:P31 wd:Q23397 ; wdt:P625 ?coord .",
      set_name: "Lakes in Massachusetts", explanation: "Lakes in Mass.",
      cannot_answer: false,
      region_name: "Massachusetts",
      region_parent_name: "United States",
      region_admin_level: "admin1"
    }
    queue_gemini_responses([ submit_answer_envelope(args) ]) do
      r = gen.generate(conversation: [ { role: "user", text: "lakes in mass" } ])
      assert_equal({ name: "Massachusetts", parent_name: "United States", admin_level: "admin1" },
                   r[:region_filter])
    end
  end

  test "region_filter is nil when admin_level is missing or invalid" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    args = {
      sparql_pattern: "?item wdt:P31 wd:Q23397 ; wdt:P625 ?coord .",
      set_name: "X", explanation: "x", cannot_answer: false,
      region_name: "Wherever", region_admin_level: "galactic_sector"
    }
    queue_gemini_responses([ submit_answer_envelope(args) ]) do
      r = gen.generate(conversation: [ { role: "user", text: "x" } ])
      assert_nil r[:region_filter]
    end
  end

  test "rate-limit error bubbles up after retries" do
    gen = AiImageSetGenerator.new(api_key: "stub")
    # Burn both attempts on HTTP 429 — the retry inside post_with_retry
    # also returns 429, then we raise.
    queue_gemini_responses([ "rate-limited", "rate-limited" ], status: 429) do
      assert_raises(AiImageSetGenerator::RateLimitError) do
        gen.generate(conversation: [ { role: "user", text: "x" } ])
      end
    end
  end

  private

  def submit_answer_envelope(args)
    {
      candidates: [ {
        content: {
          parts: [ { functionCall: { name: "submit_answer", args: args } } ]
        }
      } ]
    }.to_json
  end

  def function_call_envelope(name, args)
    {
      candidates: [ {
        content: {
          parts: [ { functionCall: { name: name, args: args } } ]
        }
      } ]
    }.to_json
  end

  # Replace a class method with a fixed value for the duration of a
  # block. Restores the original after.
  def stub_class_method(klass, method, value)
    original = klass.method(method)
    klass.define_singleton_method(method) { |*_a, **_k| value }
    yield
  ensure
    klass.define_singleton_method(method, original)
  end

  # Queue a sequence of stubbed Gemini responses. Each call to the API
  # pops one off the front. Tests with N round-trips pass N responses.
  def queue_gemini_responses(bodies, status: 200)
    queue = bodies.dup
    fake = lambda do
      body = queue.shift
      resp = Net::HTTPResponse.send(:response_class, status.to_s).new("1.1", status.to_s, "OK")
      resp.define_singleton_method(:body) { body }
      resp.define_singleton_method(:code) { status.to_s }
      resp
    end
    Net::HTTP.stub_any_instance(:request, fake) { yield }
  end
end

# Net::HTTP doesn't have stub_any_instance built in. This monkeypatch
# wraps `request` so a test can substitute a fixed response or a lambda
# that produces a different response per call (for multi-round tests).
class Net::HTTP
  def self.stub_any_instance(method, value)
    aliased = "_pre_stub_#{method}"
    alias_method(aliased, method) unless method_defined?(aliased)
    define_method(method) do |*_args, **_kw|
      value.respond_to?(:call) ? value.call : value
    end
    yield
  ensure
    if method_defined?(aliased)
      alias_method(method, aliased)
      remove_method(aliased)
    end
  end
end
