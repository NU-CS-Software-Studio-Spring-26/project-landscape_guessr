namespace :images do
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
end
