class AiGenerationJob < ApplicationJob
  queue_as :default

  # Runs the AI generation pipeline off the request thread. Web request
  # for /ai_generate returns in ~25ms (rate-limit bump + record create
  # + enqueue + redirect); this job then takes the 30-130s the Gemini +
  # WDQS calls actually need without H12-timing-out the user's browser.
  def perform(generation_id)
    gen = AiGeneration.find_by(id: generation_id)
    return unless gen

    AiGenerationPipeline.new(generation: gen).run
  rescue StandardError => e
    Rails.error.report(
      e,
      context: { job: "AiGenerationJob", generation_id: generation_id },
      handled: true
    )
    gen&.update_columns(
      status:           "failed",
      phase:            nil,
      progress_message: nil,
      error:            "#{e.class}: #{e.message.to_s.slice(0, 500)}"
    )
    raise
  end
end
