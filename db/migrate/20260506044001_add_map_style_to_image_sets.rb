class AddMapStyleToImageSets < ActiveRecord::Migration[8.1]
  def change
    # Per-set MapTiler basemap. outdoor-v2 (terrain + POIs, hiking
    # trails hidden) was the only style hardcoded everywhere; existing
    # rows keep that behavior via the default.
    add_column :image_sets, :map_style, :string, default: "outdoor-v2", null: false
  end
end
