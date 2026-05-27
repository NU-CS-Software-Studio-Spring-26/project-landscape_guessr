class ChangeGamesScoreToInteger < ActiveRecord::Migration[8.1]
  def up
    change_column :games, :score, :integer, using: "score::integer"
  end

  def down
    change_column :games, :score, :float
  end
end
