class CreateAiUsages < ActiveRecord::Migration[8.1]
  # Tracks AI-generation usage per user per day. Lives in postgres
  # (rather than Rails.cache) because the dev + prod config uses
  # :memory_store, which is process-local — a multi-worker puma would
  # count separately in each worker, and a dyno restart wipes the count.
  # Neither is what "20 generations per user per day" means.
  #
  # One row per (user, day). UPSERT semantics via the unique index +
  # ON CONFLICT, so concurrent calls don't race past the limit.
  def change
    create_table :ai_usages do |t|
      t.references :user, null: false, foreign_key: true, index: false
      t.date    :day,   null: false
      t.integer :count, null: false, default: 0
      t.timestamps
    end
    add_index :ai_usages, [ :user_id, :day ], unique: true
  end
end
