# frozen_string_literal: true

# Tracks which images remain in a "Saved for Practice" set run (session-backed).
class PracticeSetProgress
  SESSION_KEY = :practice_set_progress

  attr_reader :set_id, :total

  def self.start(session, set)
    image_ids = located_image_ids_for(set)
    session[SESSION_KEY] = {
      "set_id" => set.id,
      "remaining" => image_ids.shuffle,
      "total" => image_ids.size
    }
    new(session, session[SESSION_KEY])
  end

  def self.for(session, set_id:)
    data = session[SESSION_KEY]
    return nil unless data.is_a?(Hash) && data["set_id"].to_i == set_id.to_i

    new(session, data)
  end

  def self.clear(session)
    session.delete(SESSION_KEY)
  end

  def self.located_image_ids_for(set)
    set.effective_items
       .joins(:image)
       .where.not(images: { latitude: nil, longitude: nil })
       .pluck(:image_id)
  end

  def initialize(session, data)
    @session = session
    @data = data
    @set_id = data["set_id"].to_i
    @total = data["total"].to_i
    @remaining = Array(data["remaining"]).map(&:to_i)
  end

  def remaining
    @remaining.dup
  end

  def finished?
    @remaining.empty?
  end

  def current_image_id
    @remaining.first
  end

  def completed_count
    @total - @remaining.size
  end

  def position_label
    return "No images" if @total.zero?

    "Image #{completed_count + 1} of #{@total}"
  end

  def complete!(image_id)
    @remaining.delete(image_id.to_i)
    persist!
  end

  private

  def persist!
    @data["remaining"] = @remaining
    @session[SESSION_KEY] = @data
  end
end
