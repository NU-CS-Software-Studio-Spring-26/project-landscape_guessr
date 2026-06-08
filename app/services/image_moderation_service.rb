# Wraps AWS Rekognition's DetectModerationLabels API to screen user-uploaded
# images for inappropriate content before they are persisted.
#
# Usage:
#   ImageModerationService.safe?(s3_key: "some/key.jpg")
#   ImageModerationService.safe?(image_bytes: File.binread("/tmp/img.jpg"))
#
# Returns true  when the image is safe (or Rekognition is not configured).
# Returns false when a blocked label exceeds CONFIDENCE_THRESHOLD.
#
# Configuration (via ENV / Rails credentials):
#   AWS_ACCESS_KEY_ID        — IAM user with rekognition:DetectModerationLabels
#   AWS_SECRET_ACCESS_KEY
#   AWS_REKOGNITION_REGION   — must match your S3 bucket region (e.g. us-east-1)
#   AWS_S3_BUCKET            — bucket name, used for the S3-key call path
class ImageModerationService
  # Confidence level (0–100) above which a label is treated as a violation.
  # 75 is a reasonable starting point: catches clear violations while keeping
  # false-positive rates low for ambiguous content (e.g. art nudes, graphic
  # medical images). Tune downward to be stricter, upward to be more lenient.
  CONFIDENCE_THRESHOLD = 75.0

  # Top-level Rekognition moderation categories that are always blocked.
  # Sub-labels (e.g. "Explicit Nudity >> Graphic Sexual Activity") inherit
  # their parent's block if the parent is listed here.
  # Full label taxonomy: https://docs.aws.amazon.com/rekognition/latest/dg/moderation.html
  BLOCKED_CATEGORIES = %w[
    Explicit\ Nudity
    Violence
    Visually\ Disturbing
    Hate\ Symbols
    Drugs
    Tobacco
    Gambling
  ].freeze

  # Call with either s3_key: or image_bytes:, not both.
  #
  # s3_key path:     efficient — Rekognition fetches from S3 directly,
  #                  the Rails process never downloads the file.
  # image_bytes path: for testing or when the blob is already in memory.
  def self.safe?(s3_key: nil, image_bytes: nil)
    return true unless configured?

    labels = detect_moderation_labels(s3_key: s3_key, image_bytes: image_bytes)
    labels.none? { |label| blocked?(label) }
  rescue Aws::Rekognition::Errors::ServiceError => e
    # Log and fail open — better to let a borderline image through than to
    # break uploads entirely if Rekognition has a transient outage.
    Rails.logger.error("[ImageModerationService] Rekognition error: #{e.class}: #{e.message}")
    true
  rescue => e
    Rails.logger.error("[ImageModerationService] Unexpected error: #{e.class}: #{e.message}")
    true
  end

  # ── Private ─────────────────────────────────────────────────────────────────

  def self.configured?
    ENV["AWS_ACCESS_KEY_ID"].present? &&
      ENV["AWS_SECRET_ACCESS_KEY"].present? &&
      ENV["AWS_REKOGNITION_REGION"].present?
  end
  private_class_method :configured?

  def self.client
    @client ||= Aws::Rekognition::Client.new(
      region: ENV.fetch("AWS_REKOGNITION_REGION"),
      access_key_id:     ENV.fetch("AWS_ACCESS_KEY_ID"),
      secret_access_key: ENV.fetch("AWS_SECRET_ACCESS_KEY")
    )
  end
  private_class_method :client

  def self.detect_moderation_labels(s3_key:, image_bytes:)
    params = {
      min_confidence: CONFIDENCE_THRESHOLD,
      image: build_image_param(s3_key: s3_key, image_bytes: image_bytes)
    }
    response = client.detect_moderation_labels(params)
    response.moderation_labels
  end
  private_class_method :detect_moderation_labels

  def self.build_image_param(s3_key:, image_bytes:)
    if s3_key.present?
      bucket = ENV.fetch("AWS_S3_BUCKET") do
        # Derive bucket from the existing Active Storage S3 service config
        # so we don't require a duplicate env var in most setups.
        Rails.application.config.active_storage.service_configurations
          &.dig(Rails.application.config.active_storage.service.to_s, "bucket")
      end
      { s3_object: { bucket: bucket, name: s3_key } }
    elsif image_bytes.present?
      { bytes: image_bytes }
    else
      raise ArgumentError, "provide s3_key: or image_bytes:"
    end
  end
  private_class_method :build_image_param

  def self.blocked?(label)
    name = label.name.to_s
    confidence = label.confidence.to_f
    return false if confidence < CONFIDENCE_THRESHOLD

    BLOCKED_CATEGORIES.any? { |cat| name == cat || name.start_with?("#{cat} >>") }
  end
  private_class_method :blocked?
end
