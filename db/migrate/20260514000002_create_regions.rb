class CreateRegions < ActiveRecord::Migration[8.1]
  def change
    create_table :regions do |t|
      t.string :name, null: false
      t.string :admin_level, null: false
      t.string :iso_code
      t.bigint :parent_id
      t.jsonb :boundary

      t.timestamps
    end

    add_index :regions, :parent_id
    add_index :regions, :admin_level
    add_index :regions, [:name, :admin_level]
    add_foreign_key :regions, :regions, column: :parent_id
  end
end
