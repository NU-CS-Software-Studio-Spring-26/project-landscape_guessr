class CreateAiGenerations < ActiveRecord::Migration[8.1]
  def change
    create_table :ai_generations do |t|
      t.references :user, null: false, foreign_key: true
      t.string  :status,           null: false, default: "pending"
      t.string  :phase
      t.string  :progress_message
      t.text    :conversation_json
      t.text    :user_message
      t.text    :result_json
      t.text    :preview_json
      t.bigint  :result_count
      t.string  :model_used
      t.text    :error
      t.timestamps
    end
    add_index :ai_generations, [ :user_id, :created_at ]
  end
end
