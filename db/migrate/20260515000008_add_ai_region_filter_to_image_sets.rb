class AddAiRegionFilterToImageSets < ActiveRecord::Migration[8.1]
  # AI-generated sets can now name a sub-national region (e.g. "lakes in
  # Massachusetts"). The AI emits {name, parent_name, admin_level}; the
  # importer looks the row up in `regions` and injects a BBOX FILTER into
  # the SPARQL — much faster + more reliable than asking the AI to recall
  # bboxes or use `wdt:P131*` (which times out WDQS for sub-national
  # filters). Persist on the set so retry_import works the same as the
  # original run.
  def change
    add_column :image_sets, :ai_region_filter, :jsonb
  end
end
