class AddCustomAreasToImageSets < ActiveRecord::Migration[8.1]
  # Lets a filtered set include geometric areas not tied to a Region row —
  # currently just circles ({type: "circle", center: {lat, lng}, radius_m, name}),
  # but the schema accommodates polygons too ({type: "polygon", geojson: {...}})
  # if/when we add a drawing UI.
  #
  # jsonb on image_sets (vs a join table) because:
  # - There's no reason to share areas across sets.
  # - Always-loaded with the filtered_set, no extra query.
  # - Per-set custom areas rarely exceed a handful; jsonb performance is fine.
  def change
    add_column :image_sets, :custom_areas, :jsonb, default: [], null: false
  end
end
