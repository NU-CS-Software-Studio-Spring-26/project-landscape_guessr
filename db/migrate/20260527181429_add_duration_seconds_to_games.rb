class AddDurationSecondsToGames < ActiveRecord::Migration[8.1]
  def change
    add_column :games, :duration_seconds, :integer
  end
end
