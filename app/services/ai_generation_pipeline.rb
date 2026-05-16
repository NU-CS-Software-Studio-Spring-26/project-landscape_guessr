# Drives one AiGeneration record through the three stages of an
# AI-image-set proposal: generate (call Gemini), count (run COUNT
# against Wikidata), sample (run a 30-row preview). Updates the
# record's status/phase/progress_message as it goes so the polling UI
# can show what's happening in real time.
#
# Lives off the request thread (called by AiGenerationJob). Mirror of
# the WikidataImporter#import! state-reporting pattern: same {pending,
# running, completed, failed} lifecycle and per-phase update_columns.
#
# Why a service and not inline in the job: keeps the job a thin wrapper
# around `pipeline.run`, lets tests exercise the orchestration without
# ActiveJob's perform_enqueued_jobs harness, and isolates the
# Flash→Pro fallback + 0-result retry logic in one place.
class AiGenerationPipeline
  def initialize(generation:)
    @generation = generation
  end

  def run
    @generation.update!(status: "running", phase: "thinking", progress_message: nil)

    # conversation_json already includes the new user turn — the
    # controller appends it at create time so the in-progress thread
    # shows the typed message immediately. user_message is kept on the
    # record for ai_create + debugging but not re-appended here.
    conversation = @generation.conversation

    ai_result, model = generate_with_fallback(conversation)
    conversation << { role: "model", text: ai_result.to_json }
    @generation.update!(
      model_used:        model.to_s,
      conversation_json: conversation.to_json,
      result_json:       ai_result.to_json
    )

    if ai_result[:cannot_answer]
      @generation.update!(status: "completed", phase: nil, progress_message: nil)
      return
    end

    @generation.update!(phase: "counting", progress_message: nil)
    count = safe_count(ai_result[:sparql_pattern], fetch_strategy: ai_result[:fetch_strategy])
    @generation.update!(result_count: count)

    # Flash 0-results OR couldn't-count → silently retry on Pro. The
    # user's prompt is unchanged; the prior conversation already shows
    # Flash's attempt. We REPLACE the conversation's last model turn
    # with Pro's answer so the refinement form posts the upgraded
    # conversation forward.
    #
    # `count.to_i.zero?` matches both `0` (genuine no-match — maybe
    # Pro can compose a less-restrictive pattern) and `nil` (WDQS
    # timeout/5xx on Flash's pattern — Pro might compose a simpler
    # pattern that WDQS can actually execute, e.g. dropping a costly
    # property path). Either way, paying the Pro cost is the right
    # call before giving the user an empty/error result.
    if count.to_i.zero? && model == :flash
      # We're going back to Gemini, so the phase label needs to flip
      # away from "counting" — otherwise the polling UI shows "Counting
      # matches in Wikidata…" for the 30-60s the Pro call takes, which
      # is both inaccurate and confusing. The progress_message gives the
      # user a heads-up that this is an extra step.
      @generation.update!(
        phase:            "thinking",
        progress_message: "Flash matched 0 — trying again with a stronger model…"
      )
      pro_result = retry_on_pro(conversation[0..-2])
      if pro_result && !pro_result[:cannot_answer]
        ai_result = pro_result
        conversation[-1] = { role: "model", text: ai_result.to_json }
        # Re-enter the counting phase for the Pro answer's recount.
        @generation.update!(phase: "counting", progress_message: nil)
        count = safe_count(ai_result[:sparql_pattern], fetch_strategy: ai_result[:fetch_strategy])
        @generation.update!(
          model_used:        "pro",
          conversation_json: conversation.to_json,
          result_json:       ai_result.to_json,
          result_count:      count
        )
      end
    end

    @generation.update!(phase: "sampling", progress_message: nil)
    preview = safe_sample(
      ai_result[:sparql_pattern],
      image_source: ai_result[:image_source],
      fetch_strategy: ai_result[:fetch_strategy]
    )

    @generation.update!(
      status:       "completed",
      phase:        nil,
      preview_json: preview.to_json
    )
  end

  private

  # Same fallback shape as the prior synchronous controller helper:
  # try Flash first; if Flash throws (rate limit / malformed beyond
  # retries / 5xx), escalate to Pro for one attempt. Pro errors bubble
  # up to the job which records `failed`.
  def generate_with_fallback(conversation)
    flash = AiImageSetGenerator.new(model: :flash, progress_callback: progress_callback)
    [ flash.generate(conversation: conversation), :flash ]
  rescue AiImageSetGenerator::Error => e
    Rails.logger.warn "[ai_pipeline flash] #{e.class}: #{e.message}"
    pro = AiImageSetGenerator.new(model: :pro, progress_callback: progress_callback)
    [ pro.generate(conversation: conversation), :pro ]
  end

  def retry_on_pro(conversation)
    AiImageSetGenerator.new(model: :pro, progress_callback: progress_callback)
      .generate(conversation: conversation)
  rescue AiImageSetGenerator::Error => e
    Rails.logger.warn "[ai_pipeline pro-retry] #{e.class}: #{e.message}"
    nil
  end

  # update_columns skips validations + callbacks AND skips touching
  # updated_at — which we don't want here. We bump updated_at manually
  # so the stale? check on AiGeneration treats per-tool-call progress
  # as recent activity (otherwise a slow Gemini round with many tool
  # calls could time out the staleness check even though work is
  # happening). Use update_columns rather than update! to avoid AR
  # validations on every tool call (~5-10 calls per generation).
  def progress_callback
    @progress_callback ||= ->(message) do
      @generation.update_columns(progress_message: message, updated_at: Time.current)
    end
  end

  def safe_count(pattern, fetch_strategy:)
    t0 = Time.now
    n = WikidataImporter.count(pattern: pattern, fetch_strategy: fetch_strategy)
    Rails.logger.info "[ai_count] #{(Time.now - t0).round(2)}s -> #{n}"
    n
  rescue WikidataImporter::Error => e
    Rails.logger.warn "[ai_count] err #{e.class}: #{e.message.slice(0, 200)}"
    nil
  end

  def safe_sample(pattern, image_source:, fetch_strategy:)
    t0 = Time.now
    rows = WikidataImporter.sample(
      pattern: pattern, image_source: image_source,
      limit: 30, fetch_strategy: fetch_strategy
    )
    Rails.logger.info "[ai_sample] #{(Time.now - t0).round(2)}s -> #{rows.size} rows"
    rows
  rescue WikidataImporter::Error => e
    Rails.logger.warn "[ai_sample] err #{e.class}: #{e.message.slice(0, 200)}"
    []
  end
end
