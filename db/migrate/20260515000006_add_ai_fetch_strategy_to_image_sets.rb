class AddAiFetchStrategyToImageSets < ActiveRecord::Migration[8.1]
  # exhaustive  — fetch every matching item (current behavior, default)
  # random_sample — bd:sample-per-type, capped, no subclass walk
  def change
    add_column :image_sets, :ai_fetch_strategy, :string, default: "exhaustive"
  end
end
