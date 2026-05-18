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

  test "unresolvable region_filter fails fast with a helpful message; no Wikidata call" do
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "lakes in bayern",
      conversation_json: [ { role: "user", text: "lakes in bayern" } ].to_json
    )
    ai_with_bad_region = AI_RESULT.merge(
      region_filter: { name: "Bayern", parent_name: "Germany", admin_level: "admin1" }
    )
    count_called = false
    with_stubbed_generator(returns: ai_with_bad_region) do
      stub_class_method(WikidataImporter, :count, ->(*_a, **_k) { count_called = true; 0 }) do
        AiGenerationPipeline.new(generation: gen).run
      end
    end
    refute count_called, "count should not run when region is unresolvable"
    gen.reload
    assert_equal "failed", gen.status
    assert_match(/canonical English name|couldn't find/i, gen.error.to_s)
  end

  test "Wikidata count failure marks generation failed with actionable message; skips sample" do
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "volcanoes",
      conversation_json: [ { role: "user", text: "volcanoes" } ].to_json
    )
    sample_called = false

    with_stubbed_generator(returns: AI_RESULT) do
      raising = ->(*_a, **_k) { raise WikidataImporter::Error, "WDQS 500" }
      stub_class_method(WikidataImporter, :count, raising) do
        record_sample = ->(*_a, **_k) { sample_called = true; [] }
        stub_class_method(WikidataImporter, :sample, record_sample) do
          AiGenerationPipeline.new(generation: gen).run
        end
      end
    end

    gen.reload
    assert_equal "failed", gen.status
    assert_nil gen.result_count
    assert_match(/too busy|too expensive/i, gen.error.to_s)
    refute sample_called, "sample should not be attempted when count fails"
  end

  test "nil count does NOT trigger Pro retry (only count == 0 does)" do
    gen = AiGeneration.create!(
      user: @user, status: "pending", user_message: "volcanoes",
      conversation_json: [ { role: "user", text: "volcanoes" } ].to_json
    )
    generator_calls = 0

    with_stubbed_generator_counting(returns: AI_RESULT, counter: -> { generator_calls += 1 }) do
      raising = ->(*_a, **_k) { raise WikidataImporter::Error, "WDQS 500" }
      stub_class_method(WikidataImporter, :count, raising) do
        stub_class_method(WikidataImporter, :sample, []) do
          AiGenerationPipeline.new(generation: gen).run
        end
      end
    end

    assert_equal 1, generator_calls, "Pro retry should NOT fire on nil count"
    gen.reload
    assert_equal "failed", gen.status
  end

  test "cancel before run bails immediately at the first checkpoint" do
    gen = AiGeneration.create!(
      user: @user, status: "canceled", user_message: "volcanoes",
      conversation_json: [ { role: "user", text: "volcanoes" } ].to_json
    )
    # Even though pipeline.run will set status:"running" first, the
    # first reload-based checkpoint after the generator call will see
    # status:"canceled" written by another request (simulated by the
    # generator stub flipping the row).
    flip_to_canceled = lambda do |conversation:|
      gen.update_columns(status: "canceled")
      AI_RESULT
    end
    original = AiImageSetGenerator.instance_method(:generate)
    AiImageSetGenerator.define_method(:generate, &flip_to_canceled)
    begin
      count_called = false
      stub_class_method(WikidataImporter, :count, ->(*_a, **_k) { count_called = true; 0 }) do
        AiGenerationPipeline.new(generation: gen).run
      end
      refute count_called, "count should not run after cancel"
    ensure
      AiImageSetGenerator.define_method(:generate, original)
    end

    gen.reload
    assert_equal "canceled", gen.status
    assert_nil gen.phase
  end

  private

  # Variant of with_stubbed_generator that also counts invocations.
  def with_stubbed_generator_counting(returns:, counter:)
    original = AiImageSetGenerator.instance_method(:generate)
    AiImageSetGenerator.define_method(:generate) do |conversation:|
      counter.call
      returns
    end
    yield
  ensure
    AiImageSetGenerator.define_method(:generate, original)
  end


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
