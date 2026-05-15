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

    # Per-child rescue so one bad filter set (e.g. transient Nominatim
    # outage on boundary fetch) doesn't abandon the rest. Report to the
    # configured error subscriber so the failure is visible — bare
    # logger.error gets buried in the rolling log.
    parent.filtered_sets.find_each do |child|
      child.materialize_filtered_items!
    rescue StandardError => e
      Rails.error.report(
        e,
        context: { job: "RematerializeFilteredSetsJob", parent_image_set_id: parent.id, child_id: child.id },
        handled: true
      )
    end
  end
end
