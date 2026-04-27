class ChangeGamesScoreToFloat < ActiveRecord::Migration[8.1]
  def change
    change_column :games, :score, :float
  end
end
