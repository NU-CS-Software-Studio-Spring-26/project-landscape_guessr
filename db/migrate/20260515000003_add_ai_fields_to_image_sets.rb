class AddAiFieldsToImageSets < ActiveRecord::Migration[8.1]
  # AI-generated sets ship with the user's natural-language prompt, the
  # SPARQL query the AI produced, and import-progress state that the show
  # page polls while the background AiImportImagesJob runs.
  #
  # All columns are nullable so non-AI sets (manual uploads, filtered
  # children, default seed set) don't carry empty AI metadata.
  def change
    change_table :image_sets do |t|
      t.text   :ai_prompt
      t.text   :ai_query
      t.text   :ai_explanation
      t.string :ai_model
      t.string :ai_image_source
      t.string :import_state
      t.integer :import_total
      t.integer :import_progress, default: 0, null: false
      t.text :import_error
    end
  end
end
