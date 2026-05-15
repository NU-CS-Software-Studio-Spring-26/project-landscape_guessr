class CreateSavedPracticeImages < ActiveRecord::Migration[8.1]
  def up
    create_table :saved_practice_images do |t|
      t.references :user, null: false, foreign_key: true
      t.references :image, null: false, foreign_key: true

      t.timestamps
    end

    add_index :saved_practice_images, [ :user_id, :image_id ], unique: true
  end

  def down
    drop_table :saved_practice_images
  end
end
