class RematerializeFilteredSetsJob < ApplicationJob
  queue_as :default

  # Re-runs materialize_filtered_items! on every filtered child of the given
  # parent set. Moved off the request thread because rematerialization
  # (a) point-in-polygons every parent image against every filter region and
  # (b) lazy-fetches missing region boundaries from Nominatim at 1.1s each, both
  # of which can blow request timeouts on real-sized sets.
  def perform(parent_image_set_id)
    parent = ImageSet.find_by(id: parent_image_set_id)
    return unless parent

    parent.filtered_sets.find_each do |child|
      child.materialize_filtered_items!
    rescue => e
      Rails.logger.error("[RematerializeFilteredSetsJob] child=#{child.id} #{e.class}: #{e.message}")
    end
  end
end
