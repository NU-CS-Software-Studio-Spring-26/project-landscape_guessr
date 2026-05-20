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
  class Canceled < StandardError; end

  # Total wall-clock budget for one generation. Belt-and-suspenders on
  # top of the per-query timeouts in WikidataImporter — if a phase blows
  # past its bounds and the pipeline reaches its next checkpoint after
  # this much elapsed time, it fails the generation cleanly rather than
  # letting the user wait silently for many more minutes. Sized so the
  # worst realistic case (Flash + count fan-out + Pro retry + recount +
  # sample) fits, but a runaway doesn't.
  MAX_DURATION = 180

  def initialize(generation:)
    @generation = generation
  end

  def run
    @start_time = Time.current
    @generation.update!(status: "running", phase: "thinking", progress_message: nil)

    # conversation_json already includes the new user turn — the
    # controller appends it at create time so the in-progress thread
    # shows the typed message immediately. user_message is kept on the
    # record for ai_create + debugging but not re-appended here.
    conversation = @generation.conversation

    ai_result, model = generate_with_fallback(conversation)
    bail_if_canceled!
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

    # Validate region_filter UPFRONT — if AI emitted a region we can't
    # resolve (typo, native-language name, region not in our Region
    # table), fail with a specific message instead of silently running
    # the query without region constraint and returning global results.
    if ai_result[:region_filter] && WikidataImporter.resolve_region_filter(ai_result[:region_filter]).nil?
      rf = ai_result[:region_filter]
      label = "#{rf[:name]}#{rf[:parent_name] ? ", #{rf[:parent_name]}" : ""}"
      @generation.update!(
        status:           "failed",
        phase:            nil,
        progress_message: nil,
        error:            "I couldn't find region '#{label}' in our database. Try a canonical English name (e.g. 'Bavaria' not 'Bayern', 'United States' not 'USA')."
      )
      return
    end

    check_deadline!
    @generation.update!(phase: "counting", progress_message: nil)
    count = safe_count(
      ai_result[:sparql_pattern],
      region_filter: ai_result[:region_filter]
    )
    bail_if_canceled!
    @generation.update!(result_count: count)

    # Pro retry ONLY on count == 0, NOT on nil.
    #   count == 0 means Flash's SPARQL ran fine and genuinely returned
    #     no matches — Pro might compose a less-restrictive pattern.
    #   count == nil means every per-type query errored or timed out
    #     against WDQS (catastrophic case: P131* + broad classes). Pro
    #     re-running the same shape just doubles the wasted wall time.
    #     Surface the failure so the user can simplify.
    if count == 0 && model == :flash
      check_deadline!
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
      bail_if_canceled!
      if pro_result && !pro_result[:cannot_answer]
        ai_result = pro_result
        conversation[-1] = { role: "model", text: ai_result.to_json }
        check_deadline!
        # Re-enter the counting phase for the Pro answer's recount.
        # CRITICAL: pass region_filter through here too — without it, the
        # Pro-retry count is unfiltered (fan-out across every type, no
        # SERVICE wikibase:box) and takes ~90s for a broad umbrella.
        @generation.update!(phase: "counting", progress_message: nil)
        count = safe_count(
          ai_result[:sparql_pattern],
          region_filter: ai_result[:region_filter]
        )
        bail_if_canceled!
        @generation.update!(
          model_used:        "pro",
          conversation_json: conversation.to_json,
          result_json:       ai_result.to_json,
          result_count:      count
        )
      end
    end

    # Count failed entirely (every per-type query errored/timed out).
    # Don't pay another fan-out wall for a sample that will fail the
    # same way. Mark failed with an actionable message.
    if count.nil?
      @generation.update!(
        status:           "failed",
        phase:            nil,
        progress_message: nil,
        error:            "Wikidata is too busy or this query is too expensive. Try simplifying your prompt (narrower region, fewer categories), or wait a minute and try again."
      )
      return
    end

    check_deadline!
    @generation.update!(phase: "sampling", progress_message: nil)
    preview = safe_sample(
      ai_result[:sparql_pattern],
      region_filter: ai_result[:region_filter]
    )
    bail_if_canceled!

    @generation.update!(
      status:       "completed",
      phase:        nil,
      preview_json: preview.to_json
    )
  rescue Canceled
    # User-initiated cancel hit a checkpoint. Leave status as "canceled"
    # (set by the cancel endpoint); just clear the per-phase noise.
    @generation.update_columns(phase: nil, progress_message: nil)
  end

  private

  # Re-reads status from DB; raises Canceled if the cancel endpoint
  # has flipped the row to "canceled". The rescue Canceled at the
  # bottom of run handles cleanup (clearing phase/progress_message).
  def bail_if_canceled!
    raise Canceled if @generation.reload.status == "canceled"
  end

  # Belt-and-suspenders deadline guard. If the wall budget is blown,
  # mark failed with a clear message and raise Canceled to short-
  # circuit through the same exit path. The rescue's update_columns
  # leaves status="failed" intact (only touches phase/progress_message).
  def check_deadline!
    return unless @start_time && (Time.current - @start_time) > MAX_DURATION
    @generation.update!(
      status:           "failed",
      phase:            nil,
      progress_message: nil,
      error:            "Generation took too long (#{MAX_DURATION}s budget). Try simplifying your prompt."
    )
    raise Canceled
  end


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

  def safe_count(pattern, region_filter: nil)
    t0 = Time.now
    n = WikidataImporter.count(
      pattern: pattern, region_filter: region_filter,
      on_progress: lambda do |done, total, sum|
        # Live running total in the polling UI: "Counted 5 of 14
        # categories — 1,234 matching items so far". Gives the user
        # a visible sign of progress even when individual per-type
        # queries take 20-40s for big classes.
        @generation.update_columns(
          progress_message: "Counted #{done} of #{total} #{'category'.pluralize(total)} — " \
                            "#{ActiveSupport::NumberHelper.number_to_delimited(sum)} matching items so far"
        )
      end
    )
    Rails.logger.info "[ai_count] #{(Time.now - t0).round(2)}s -> #{n.inspect}"
    n
  rescue WikidataImporter::Error => e
    Rails.logger.warn "[ai_count] err #{e.class}: #{e.message.slice(0, 200)}"
    nil
  end

  def safe_sample(pattern, region_filter: nil)
    t0 = Time.now
    rows = WikidataImporter.sample(
      pattern: pattern, limit: 30, region_filter: region_filter,
      on_progress: lambda do |done, total, _qid|
        # No running thumb count here — sample's block returns rows
        # (not a number), and the per-type oversample target isn't
        # what the user actually cares about. Per-category progress
        # is enough.
        @generation.update_columns(
          progress_message: "Loading preview images: #{done} of #{total} #{'category'.pluralize(total)}…"
        )
      end
    )
    Rails.logger.info "[ai_sample] #{(Time.now - t0).round(2)}s -> #{rows.size} rows"
    rows
  rescue WikidataImporter::Error => e
    Rails.logger.warn "[ai_sample] err #{e.class}: #{e.message.slice(0, 200)}"
    []
  end
end
