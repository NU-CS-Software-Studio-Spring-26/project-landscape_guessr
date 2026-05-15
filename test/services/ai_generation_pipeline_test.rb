require "test_helper"

# End-to-end test for the orchestration: generator + Wikidata count +
# sample. We stub the three external collaborators (generator, count,
# sample) so we exercise the state-machine transitions without
# hitting Gemini or WDQS. Mirrors the stubbing pattern in
# test/services/ai_image_set_generator_test.rb.
class AiGenerationPipelineTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
  end

  AI_RESULT = {
    sparql_pattern: "?item wdt:P31 wd:Q8072 ; wdt:P625 ?coord .",
    set_name:       "Volcanoes",
    explanation:    "Volcanoes worldwide.",
    image_source:   "wikipedia_pageimages",
    cannot_answer:  false
  }.freeze

  test "happy path: pending → running → completed; phase clears at the end" do
    # The controller seeds conversation_json with the user turn; the
    # pipeline assumes that's already done and just appends the AI's
    # reply. Mirror that invariant in the test fixture.
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "volcanoes",
      conversation_json: [ { role: "user", text: "volcanoes" } ].to_json
    )

    with_stubbed_generator(returns: AI_RESULT) do
      stub_class_method(WikidataImporter, :count, 42) do
        stub_class_method(WikidataImporter, :sample, [ sample_row("Mt. Foo") ]) do
          AiGenerationPipeline.new(generation: gen).run
        end
      end
    end

    gen.reload
    assert_equal "completed", gen.status
    assert_nil   gen.phase
    assert_equal 42, gen.result_count
    assert_equal "flash", gen.model_used
    assert_equal 1, gen.preview.size
    refute_nil   gen.result
    assert_equal "Volcanoes", gen.result[:set_name]
    # The conversation now contains both the user turn and the AI's reply.
    assert_equal 2, gen.conversation.size
    assert_equal "model", gen.conversation.last[:role]
  end

  test "cannot_answer short-circuits before count/sample" do
    refusal = AI_RESULT.merge(sparql_pattern: "", cannot_answer: true, explanation: "Too vague.")
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "things",
      conversation_json: [ { role: "user", text: "things" } ].to_json
    )

    # No count/sample stubs — pipeline must not call them. If it does,
    # the real WikidataImporter.count would attempt a network call and
    # the test would fail with a network-related error.
    with_stubbed_generator(returns: refusal) do
      AiGenerationPipeline.new(generation: gen).run
    end

    gen.reload
    assert_equal "completed", gen.status
    assert_nil   gen.phase
    assert_nil   gen.result_count
    assert_equal [], gen.preview
    assert gen.result[:cannot_answer]
  end

  test "0-result Flash answer triggers a Pro retry that replaces the conversation's last turn" do
    flash_answer = AI_RESULT.merge(sparql_pattern: "?item wdt:P31 wd:Q_obscure .")
    pro_answer   = AI_RESULT.merge(set_name: "Volcanoes (better)", sparql_pattern: "?item wdt:P31 wd:Q8072 ; wdt:P625 ?coord .")
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "volcanoes",
      conversation_json: [ { role: "user", text: "volcanoes" } ].to_json
    )

    # First call returns Flash's answer; second call (the Pro retry)
    # returns the corrected answer. The generator stub is sequenced.
    with_stubbed_generator(returns: [ flash_answer, pro_answer ]) do
      # First count = 0 (Flash flop) → triggers retry → second count = 5.
      counts = [ 0, 5 ]
      stub_class_method(WikidataImporter, :count, -> { counts.shift }) do
        stub_class_method(WikidataImporter, :sample, []) do
          AiGenerationPipeline.new(generation: gen).run
        end
      end
    end

    gen.reload
    assert_equal "completed", gen.status
    assert_equal "pro", gen.model_used
    assert_equal 5,     gen.result_count
    assert_equal "Volcanoes (better)", gen.result[:set_name]
  end

  test "Wikidata count failure leaves result_count nil but generation completes" do
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "volcanoes",
      conversation_json: [ { role: "user", text: "volcanoes" } ].to_json
    )

    with_stubbed_generator(returns: AI_RESULT) do
      raising = ->(*_a, **_k) { raise WikidataImporter::Error, "WDQS 500" }
      stub_class_method(WikidataImporter, :count, raising) do
        stub_class_method(WikidataImporter, :sample, []) do
          AiGenerationPipeline.new(generation: gen).run
        end
      end
    end

    gen.reload
    assert_equal "completed", gen.status
    assert_nil gen.result_count
  end

  private

  def sample_row(title)
    {
      item:    "http://www.wikidata.org/entity/Q1",
      title:   title,
      url:     "https://commons.wikimedia.org/wiki/Special:FilePath/Foo.jpg",
      lat:     35.0,
      lng:     139.0,
      article: nil
    }
  end

  # Replace AiImageSetGenerator#generate with a stub for the block's
  # duration. Pass a single hash to return the same answer every call,
  # or an array to return a different answer per call (Flash→Pro flow).
  # NOTE: don't use Kernel#Array on a Hash — it would flatten to
  # [[k, v], ...] pairs, which the pipeline then can't index with :keys.
  def with_stubbed_generator(returns:)
    queue = returns.is_a?(Array) ? returns.dup : [ returns ]
    original = AiImageSetGenerator.instance_method(:generate)
    AiImageSetGenerator.define_method(:generate) do |conversation:|
      queue.shift || queue.last
    end
    yield
  ensure
    AiImageSetGenerator.define_method(:generate, original)
  end

  # Replace a class method on `klass` with `value` (or a callable) for
  # the block's duration. The value is returned as-is on every call;
  # for per-call sequencing (e.g. Flash→Pro retry), pass a callable
  # (-> { queue.shift }) instead of an array — auto-treating arrays
  # as sequences would break when the actual return type IS an array
  # (e.g. WikidataImporter.sample's preview rows).
  def stub_class_method(klass, method, value)
    original = klass.method(method)
    klass.define_singleton_method(method) do |*_a, **_k|
      value.respond_to?(:call) ? value.call : value
    end
    yield
  ensure
    klass.define_singleton_method(method, original) if original
  end
end
