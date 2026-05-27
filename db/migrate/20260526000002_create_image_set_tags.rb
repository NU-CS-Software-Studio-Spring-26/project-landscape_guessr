class CreateImageSetTags < ActiveRecord::Migration[8.1]
  def change
    create_table :image_set_tags do |t|
      t.references :image_set, null: false, foreign_key: true
      t.references :tag, null: false, foreign_key: true
      t.timestamps
    end

    add_index :image_set_tags, [ :image_set_id, :tag_id ], unique: true
  end
end
