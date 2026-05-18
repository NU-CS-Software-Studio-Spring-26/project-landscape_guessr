class CreateImageAiHints < ActiveRecord::Migration[8.1]
  def up
    create_table :image_ai_hints do |t|
      t.references :image, null: false, foreign_key: true
      t.integer :tier, null: false
      t.string :status, null: false, default: "pending"
      t.text :body
      t.string :model
      t.integer :prompt_version, null: false, default: 1
      t.text :error_message

      t.timestamps
    end

    add_index :image_ai_hints,
              [ :image_id, :tier ],
              unique: true,
              name: "index_image_ai_hints_on_image_id_and_tier"
  end

  def down
    drop_table :image_ai_hints
  end
end
