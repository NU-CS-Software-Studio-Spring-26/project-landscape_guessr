class CreateChallenges < ActiveRecord::Migration[8.1]
  def change
    create_table :challenges do |t|
      t.references :challenger, null: false, foreign_key: { to_table: :users }
      t.references :image_set,  null: true,  foreign_key: true
      t.string :token, null: false
      t.timestamps
    end

    add_index :challenges, :token, unique: true
  end
end
