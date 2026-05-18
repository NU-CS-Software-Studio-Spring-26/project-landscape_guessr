class DropImageRegions < ActiveRecord::Migration[8.1]
  def up
    drop_table :image_regions, if_exists: true
  end

  def down
    create_table :image_regions do |t|
      t.references :image, null: false, foreign_key: true
      t.references :region, null: false, foreign_key: true

      t.timestamps
    end

    add_index :image_regions, [ :image_id, :region_id ], unique: true
  end
end
