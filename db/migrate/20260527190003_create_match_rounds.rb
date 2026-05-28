class CreateMatchRounds < ActiveRecord::Migration[8.1]
  def change
    create_table :match_rounds do |t|
      t.references :match, null: false, foreign_key: true
      t.integer    :index, null: false
      t.references :image, null: false, foreign_key: true
      t.decimal    :answer_latitude,  precision: 10, scale: 6, null: false
      t.decimal    :answer_longitude, precision: 10, scale: 6, null: false
      t.datetime   :started_at, null: false
      t.datetime   :deadline_at, null: false
      t.datetime   :ended_at

      t.timestamps
    end

    add_index :match_rounds, [ :match_id, :index ], unique: true
  end
end
