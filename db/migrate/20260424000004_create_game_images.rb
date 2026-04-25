class CreateGameImages < ActiveRecord::Migration[8.1]
  def change
    create_table :game_images do |t|
      t.references :game, null: false, foreign_key: true
      t.references :image, null: false, foreign_key: true
      t.integer :position, null: false

      t.timestamps
    end

    add_index :game_images, [ :game_id, :position ], unique: true
  end
end
