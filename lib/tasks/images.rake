namespace :images do
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
