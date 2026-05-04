class AddAnswerCoordsToGameImages < ActiveRecord::Migration[8.1]
  def change
    add_column :game_images, :answer_latitude, :decimal
    add_column :game_images, :answer_longitude, :decimal
  end
end
