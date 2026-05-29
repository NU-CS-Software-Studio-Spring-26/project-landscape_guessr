class AddImportedAtToAiGenerations < ActiveRecord::Migration[8.1]
  # Marks a completed AI proposal as already-imported so it can't be replayed.
  # `ai_create` (which enqueues the expensive WDQS/Commons/Mapillary fan-out)
  # has no rate limit of its own — only `ai_generate` does — so without this a
  # user could POST the same `generation_id` repeatedly and trigger unbounded
  # imports. One import per proposal bounds imports to the 20/day generation cap.
  def change
    add_column :ai_generations, :imported_at, :datetime
  end
end
