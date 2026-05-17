namespace :images do
  desc "Re-enqueue ProcessImageJob for any image whose attached blob isn't marked processed yet. Run this after a dyno restart (deploy, daily cycle, OOM) — the :async adapter is in-memory, so anything queued at restart time is lost. Idempotent."
  task reprocess_pending: :environment do
    enqueued = 0
    Image.joins(:photo_attachment).find_each do |image|
      next if image.processed?
      ProcessImageJob.perform_later(image)
      enqueued += 1
    end
    puts "[images:reprocess_pending] enqueued #{enqueued} ProcessImageJob(s)"
  end

  desc "Destroy Image rows that aren't referenced by any image_set_items, game_images, or guesses. The has_one_attached cascade purges the S3 blob too (no-ops gracefully if the blob is already gone)."
  task destroy_orphans: :environment do
    scope = Image.where.not(id: ImageSetItem.select(:image_id))
                 .where.not(id: GameImage.select(:image_id))
                 .where.not(id: Guess.select(:image_id))
    count = scope.count
    scope.find_each(&:destroy)
    puts "[images:destroy_orphans] destroyed #{count} orphan image(s)"
  end

  desc "Purge Active Storage blobs created by direct-upload that never got an attachment (failed/aborted batches). Default: blobs older than 1 hour. Pass [N] to override."
  task :purge_unattached, [ :hours ] => :environment do |_, args|
    hours  = (args[:hours] || 1).to_i
    cutoff = hours.hours.ago
    scope  = ActiveStorage::Blob.unattached.where("active_storage_blobs.created_at < ?", cutoff)
    count  = scope.count
    scope.find_each(&:purge_later)
    puts "[images:purge_unattached] enqueued #{count} unattached blob(s) older than #{hours}h"
  end

  desc "Backfill metadata.processed=true on Active Storage blobs that pre-date the direct-upload migration. Safe to re-run."
  task mark_legacy_processed: :environment do
    scope = ActiveStorage::Blob.where(content_type: "image/jpeg")
    fixed = 0
    scope.find_each do |blob|
      next if blob.metadata["processed"]
      blob.update!(metadata: blob.metadata.merge("processed" => true))
      fixed += 1
    end
    puts "[images:mark_legacy_processed] marked #{fixed} JPEG blob(s) as processed (out of #{scope.count})"
  end

  desc <<~DESC.squish
    Pre-generate cached AI hints for located images (default: system default ImageSet;
    SCOPE=all for every located image). Args: tier (1–3, required), limit (optional),
    sleep_seconds (default 4, ~15 RPM on Gemini free tier). Idempotent — skips ready
    hints at the current prompt version and pending rows. ~1400 images × 4s ≈ 93 min/tier.
  DESC
  task :generate_ai_hints, %i[tier limit sleep_seconds] => :environment do |_t, args|
    tier = args[:tier].to_i
    unless ImageAiHint::TIERS.include?(tier)
      abort "[images:generate_ai_hints] tier is required and must be 1, 2, or 3"
    end

    limit = args[:limit].presence&.to_i
    sleep_seconds = args[:sleep_seconds].presence&.to_f || 4.0

    result = AiHintsBackfill.run(
      tier: tier,
      limit: limit,
      sleep_seconds: sleep_seconds,
      scope: ENV["SCOPE"]
    )
    puts "[images:generate_ai_hints] tier=#{tier} enqueued #{result.enqueued}, skipped #{result.skipped}"
  rescue AiHintsBackfill::Disabled => e
    abort "[images:generate_ai_hints] #{e.message}"
  end

  namespace :generate_ai_hints do
    desc "Count image_ai_hints rows by tier and status (ready / pending / failed)"
    task stats: :environment do
      AiHintsBackfill.stats.each do |tier, statuses|
        puts "[images:generate_ai_hints:stats] tier #{tier}: " \
             "ready=#{statuses['ready']} pending=#{statuses['pending']} failed=#{statuses['failed']}"
      end
    end
  end
end
