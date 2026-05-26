# frozen_string_literal: true

# Tracks a practice-set run in the session.
#
# The session stores only the set_id, total image count, and the list of
# *completed* image IDs (starts empty, grows by one per round).  The list of
# *remaining* IDs is computed on demand from the database so that large image
# sets never overflow the 4 KB cookie limit.
class PracticeSetProgress
  SESSION_KEY = :practice_set_progress

  attr_reader :set_id, :total

  # Begin a new run.  Pass the precomputed +all_ids+ array (already fetched by
  # the caller) to avoid a redundant DB query.
  def self.start(session, set, all_ids: nil)
    ids = all_ids || located_image_ids_for(set)
    session[SESSION_KEY] = {
      "set_id"        => set.id,
      "completed_ids" => [],
      "total"         => ids.size
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
    # Prefer new completed_ids format; fall back to [] for legacy sessions that
    # stored remaining IDs (those sessions simply restart from the beginning).
    @completed_ids = Array(data["completed_ids"]).map(&:to_i)
  end

  # Returns image IDs not yet completed in this run.
  # +all_ids+ must be supplied by the caller (fetched from the DB once per
  # request) so this method never issues its own query.
  def remaining(all_ids:)
    (all_ids - @completed_ids).uniq
  end

  def finished?
    @completed_ids.size >= @total
  end

  # Returns a random image ID from the remaining images.
  def current_image_id(all_ids:)
    remaining(all_ids: all_ids).sample
  end

  def completed_count
    @completed_ids.size
  end

  def position_label
    return "No images" if @total.zero?

    "Image #{completed_count + 1} of #{@total}"
  end

  def complete!(image_id)
    @completed_ids << image_id.to_i unless @completed_ids.include?(image_id.to_i)
    persist!
  end

  private

  def persist!
    @data["completed_ids"] = @completed_ids
    @data.delete("remaining") # Remove legacy key if present
    @session[SESSION_KEY] = @data
  end
end
