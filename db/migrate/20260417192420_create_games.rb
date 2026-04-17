class CreateGames < ActiveRecord::Migration[8.1]
  def change
    create_table :games do |t|
      t.string :status
      t.integer :score
      t.datetime :completed_at

      t.timestamps
    end
  end
end
