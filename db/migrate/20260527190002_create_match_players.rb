class CreateMatchPlayers < ActiveRecord::Migration[8.1]
  def change
    create_table :match_players do |t|
      t.references :match, null: false, foreign_key: true
      t.references :user,  null: false, foreign_key: true
      t.datetime   :joined_at, null: false
      t.datetime   :left_at
      t.datetime   :forfeited_at
      t.integer    :total_score, null: false, default: 0

      t.timestamps
    end

    add_index :match_players, [ :match_id, :user_id ], unique: true
  end
end
