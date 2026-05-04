class CreateImageSets < ActiveRecord::Migration[8.1]
  def change
    create_table :image_sets do |t|
      t.string :name, null: false
      t.references :user, null: true, foreign_key: true
      t.string :visibility, null: false, default: "private"
      t.boolean :is_system_default, null: false, default: false

      t.timestamps
    end

    # At most one system default set
    add_index :image_sets, :is_system_default,
              unique: true,
              where: "is_system_default = TRUE",
              name: "index_image_sets_one_system_default"
  end
end
