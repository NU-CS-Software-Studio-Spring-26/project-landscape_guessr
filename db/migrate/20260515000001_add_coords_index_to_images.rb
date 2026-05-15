class AddCoordsIndexToImages < ActiveRecord::Migration[8.1]
  # Used by GamesController#compute_set_image_bbox (MIN/MAX over the set's
  # images) and ImageSet#compute_matching_image_ids (point-in-polygon
  # candidate scan). Partial index — most filtering / aggregation paths
  # already exclude null coords, and the index stays small.
  def change
    add_index :images, [ :latitude, :longitude ],
              where: "latitude IS NOT NULL AND longitude IS NOT NULL",
              name: "index_images_on_coords_not_null"
  end
end
