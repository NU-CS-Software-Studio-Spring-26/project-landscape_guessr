class AiImportImagesJob < ApplicationJob
  queue_as :default

  # Runs an AI-generated SPARQL pattern against Wikidata and imports
  # the resulting items into the given ImageSet. Off the request thread
  # because (a) the SPARQL query itself can take up to 60s on big
  # categories, and (b) we always batch-call the MediaWiki pageimages
  # API at ~200ms per 50-title batch, which for a 10k-row import takes
  # ~40s. Either of those blows request timeouts.
  #
  # Progress is reported by mutating image_set.import_progress /
  # import_total; the show page polls /processing_status (we extend it
  # to include AI import state) and reflects progress to the user.
  def perform(image_set_id)
    image_set = ImageSet.find_by(id: image_set_id)
    return unless image_set

    image_set.update_columns(import_state: "importing", import_error: nil, import_progress: 0)

    WikidataImporter.import!(
      image_set:      image_set,
      pattern:        image_set.ai_query,
      fetch_strategy: image_set.ai_fetch_strategy.presence || "exhaustive",
      region_filter:  image_set.ai_region_filter
    )

    # If the parent had filtered children (uncommon for AI sets, but
    # possible if a user filters one), refresh them so they reflect the
    # new images.
    RematerializeFilteredSetsJob.perform_later(image_set.id) if image_set.filtered_sets.exists?

    image_set.update_columns(import_state: "completed")
  rescue StandardError => e
    Rails.error.report(
      e,
      context: { job: "AiImportImagesJob", image_set_id: image_set_id },
      handled: true
    )
    if image_set
      image_set.update_columns(
        import_state: "failed",
        import_error: "#{e.class}: #{e.message.to_s.slice(0, 500)}"
      )
    end
    # Don't re-raise. The user-visible signal is import_state="failed"
    # plus the retry button on the show page. Re-raising tells ActiveJob
    # to retry the job, which on a real backend (SolidQueue, Sidekiq)
    # would re-run the entire 60s+ import with default backoff — a
    # persistent failure (bad pattern, rate limit) would hammer WDQS
    # repeatedly with no chance of succeeding. The owner retries
    # manually when they want.
  end
end
