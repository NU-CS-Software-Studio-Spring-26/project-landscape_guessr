class AddCoordsToImages < ActiveRecord::Migration[8.1]
  def change
    # coords stored as a 2-element array [longitude, latitude] for GeoJSON compat
    # The actual spatial queries use the image_regions join table, not this column.
    # This is just for quick reference and future PostGIS upgrade.
  end
end
