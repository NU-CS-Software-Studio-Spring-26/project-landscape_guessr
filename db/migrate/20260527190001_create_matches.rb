class CreateMatches < ActiveRecord::Migration[8.1]
  def change
    create_table :matches do |t|
      t.references :host, null: false, foreign_key: { to_table: :users }
      t.references :image_set, null: false, foreign_key: true
      t.string   :status, null: false, default: "lobby"
      t.string   :code, null: false
      t.integer  :rounds_total, null: false, default: 5
      t.integer  :seconds_per_round, null: false, default: 60
      t.datetime :started_at
      t.datetime :finished_at

      t.timestamps
    end

    add_index :matches, :code, unique: true
    add_index :matches, :status
  end
end
