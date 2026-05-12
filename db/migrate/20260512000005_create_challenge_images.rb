class CreateChallengeImages < ActiveRecord::Migration[8.1]
  def change
    create_table :challenge_images do |t|
      t.references :challenge, null: false, foreign_key: true
      t.references :image,     null: false, foreign_key: true
      t.integer  :position,          null: false
      t.decimal  :answer_latitude
      t.decimal  :answer_longitude
      t.timestamps
    end

    add_index :challenge_images, [:challenge_id, :position], unique: true
  end
end
