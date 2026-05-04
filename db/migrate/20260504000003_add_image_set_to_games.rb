class AddImageSetToGames < ActiveRecord::Migration[8.1]
  def change
    add_reference :games, :image_set, null: true, foreign_key: true
  end
end
