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

    region_resolved = image_set.ai_region_filter ? RegionResolver.resolve(image_set.ai_region_filter) : nil
    params = image_set.ai_source_params || {}

    # The proposal phase resolved the region fine, but the job re-resolves here
    # (minutes later, fresh process). A transient Nominatim/WDQS hiccup that now
    # returns nil would make the importers silently no-op (`return unless
    # region_resolved&.bbox`) and we'd mark the set "completed" with ZERO images
    # and no error. Fail loudly instead — the user gets the Restart button.
    if image_set.ai_region_filter.present? && region_resolved.nil?
      raise "Couldn't resolve this set's region right now (the geocoding service may be briefly unavailable). Use Restart to try again."
    end

    case image_set.ai_image_source
    when "commons"
      commons_category = CommonsCategoryResolver.resolve(
        topic_qid: params["topic_qid"], combined_qid: params["combined_qid"],
        region_label: region_resolved&.label
      )
      if commons_category.blank? && params["commons_intitle_fallback"].blank?
        raise "Couldn't resolve a Commons category for this set right now. Use Restart to try again."
      end
      CommonsImporter.import!(
        image_set:        image_set,
        commons_category: commons_category,
        intitle_fallback: params["commons_intitle_fallback"],
        region_resolved:  CommonsImporter.effective_region(region_resolved: region_resolved, topic_qid: params["topic_qid"]),
        expected_count:   params["expected_count"]
      )
    when "mapillary"
      MapillaryImporter.import!(
        image_set:       image_set,
        region_resolved: region_resolved,
        min_year:        params["mapillary_min_year"]
      )
    else
      WikidataImporter.import!(
        image_set:     image_set,
        pattern:       image_set.ai_query,
        region_filter: region_resolved
      )
    end

    # If the parent had filtered children (uncommon for AI sets, but
    # possible if a user filters one), refresh them so they reflect the
    # new images.
    RematerializeFilteredSetsJob.perform_later(image_set.id) if image_set.filtered_sets.exists?

    # Never report a silent "completed" empty set. A genuine 0 (sparse coverage,
    # a category with nothing geotagged in-region) is surfaced as a clear
    # message + Restart button rather than an empty gallery with no explanation.
    if image_set.images.count.zero?
      image_set.update_columns(
        import_state: "failed",
        import_error: "No images found for this query. The area may have no coverage for this source — try a broader region or a different prompt."
      )
      return
    end

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
