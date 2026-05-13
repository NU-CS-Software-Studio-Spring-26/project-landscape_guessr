class AddChallengeIdToGames < ActiveRecord::Migration[8.1]
  def change
    add_reference :games, :challenge, null: true, foreign_key: true
  end
end
