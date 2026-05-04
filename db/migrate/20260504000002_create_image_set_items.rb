class CreateImageSetItems < ActiveRecord::Migration[8.1]
  def change
    create_table :image_set_items do |t|
      t.references :image_set, null: false, foreign_key: true
      t.references :image, null: false, foreign_key: true
      t.decimal :latitude
      t.decimal :longitude

      t.timestamps
    end

    add_index :image_set_items, [ :image_set_id, :image_id ], unique: true
  end
end
