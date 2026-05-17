# frozen_string_literal: true

class GenerateAiHintJob < ApplicationJob
  queue_as :default

  retry_on GeminiHintGenerator::RetryableError, wait: :polynomially_longer, attempts: 5

  def perform(image_id, tier)
    image = Image.find_by(id: image_id)
    unless image
      Rails.logger.warn "[GenerateAiHintJob] image=#{image_id} not found, skipping"
      return
    end

    if coordinates_missing?(image)
      mark_failed!(image, tier, "No coordinates for location-based hint")
      return
    end

    hint = ImageAiHint.find_or_initialize_by(image: image, tier: tier)
    if hint.status == "ready" && hint.prompt_version == GeminiHintGenerator::PROMPT_VERSION
      Rails.logger.info "[GenerateAiHintJob] image=#{image_id} tier=#{tier} already ready, skipping"
      return
    end

    hint.update!(status: "pending", body: nil, model: nil, error_message: nil)

    location = HintLocationContext.for_image(image)
    if location.blank?
      mark_failed!(image, tier, "Could not geocode coordinates for hint")
      return
    end

    filtered_hint = GeminiHintGenerator.generate(image: image, tier: tier, location: location)

    hint.update!(
      status: "ready",
      body: filtered_hint,
      model: GeminiConfig.model,
      prompt_version: GeminiHintGenerator::PROMPT_VERSION,
      error_message: nil
    )
    Rails.logger.info "[GenerateAiHintJob] image=#{image_id} tier=#{tier} ready"
  rescue GeminiHintGenerator::RetryableError
    raise
  rescue GeminiHintGenerator::ConfigurationError, GeminiHintGenerator::ApiError => e
    mark_failed!(image, tier, e.message) if image
  rescue StandardError => e
    mark_failed!(image, tier, e.message) if image
    raise
  end

  private

  def coordinates_missing?(image)
    image.latitude.blank? || image.longitude.blank?
  end

  def mark_failed!(image, tier, message)
    hint = ImageAiHint.find_or_initialize_by(image: image, tier: tier)
    hint.update!(status: "failed", error_message: message)
    Rails.logger.warn "[GenerateAiHintJob] image=#{image.id} tier=#{tier} failed: #{message}"
  end
end
