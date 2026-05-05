namespace :images do
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
