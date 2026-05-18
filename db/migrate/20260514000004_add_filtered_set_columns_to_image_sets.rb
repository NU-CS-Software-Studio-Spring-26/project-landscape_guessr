class AddFilteredSetColumnsToImageSets < ActiveRecord::Migration[8.1]
  def change
    add_reference :image_sets, :parent_image_set, foreign_key: { to_table: :image_sets }, null: true
    add_column :image_sets, :region_ids, :bigint, array: true, default: []
    add_index :image_sets, :region_ids, using: :gin
  end
end
