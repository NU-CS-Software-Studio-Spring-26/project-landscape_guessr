class ProcessImageJob < ApplicationJob
  queue_as :default

  # Processes an Image whose `photo` is currently the raw original (e.g. a
  # HEIC just direct-uploaded to S3). Downloads the blob, runs the same
  # vips pipeline as inline uploads (resize, icc_transform, JPEG re-encode),
  # extracts EXIF GPS, then replaces the attachment with the processed
  # JPEG. Marked idempotent via blob.metadata["processed"].
  def perform(image)
    return unless image.photo.attached?
    blob = image.photo.blob
    if blob.metadata["processed"]
      Rails.logger.info "[ProcessImageJob] image=#{image.id} already processed, skipping"
      return
    end

    started = Time.current
    Rails.logger.info "[ProcessImageJob] image=#{image.id} blob=#{blob.id} filename=#{blob.filename} starting"

    blob.open do |file|
      if image.latitude.blank? || image.longitude.blank?
        if (gps = Image.gps_from_upload(file))
          image.update_columns(latitude: gps[0], longitude: gps[1])
          Rails.logger.info "[ProcessImageJob] image=#{image.id} gps=#{gps.inspect}"
        end
      end

      processed = Image.process_path(file.path, blob.filename.to_s)
      # Stamp "processed" at blob-creation time, not after, so it lives in
      # the same INSERT as the row itself. The auto-enqueued AnalyzeJob
      # then deserializes the blob *after* commit, reads metadata with
      # "processed" already present, and merges its own keys on top —
      # closing the race where AnalyzeJob's update! could clobber a
      # post-attach metadata write.
      image.photo.attach(processed.merge(metadata: { "processed" => true }))
    end

    # Backfill ImageSetItem coords from the image's newly-extracted GPS so
    # the locations editor pre-fills correctly when the user opens it.
    if image.latitude.present? && image.longitude.present?
      image.image_set_items.where(latitude: nil, longitude: nil).update_all(
        latitude: image.latitude, longitude: image.longitude
      )
    end

    Rails.logger.info "[ProcessImageJob] image=#{image.id} done in #{(Time.current - started).round(2)}s"
  end
end
