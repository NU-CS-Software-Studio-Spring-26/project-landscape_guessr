class CreateMatchGuesses < ActiveRecord::Migration[8.1]
  def change
    create_table :match_guesses do |t|
      t.references :match_round,  null: false, foreign_key: true
      t.references :match_player, null: false, foreign_key: true
      t.decimal    :latitude,  precision: 10, scale: 6, null: false
      t.decimal    :longitude, precision: 10, scale: 6, null: false
      t.decimal    :distance_km, precision: 12, scale: 3
      t.integer    :score
      t.datetime   :submitted_at, null: false

      t.timestamps
    end

    add_index :match_guesses,
              [ :match_round_id, :match_player_id ],
              unique: true,
              name: "index_match_guesses_on_round_and_player"
  end
end
