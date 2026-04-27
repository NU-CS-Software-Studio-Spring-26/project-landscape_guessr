class AddUserToGames < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM guesses"
    execute "DELETE FROM games"
    add_reference :games, :user, null: false, foreign_key: true, index: true
  end

  def down
    remove_reference :games, :user, foreign_key: true
  end
end
