class AddAiSources < ActiveRecord::Migration[8.1]
  def change
    add_column :image_sets, :ai_image_source, :string, default: "wikidata", null: false
    add_column :image_sets, :ai_source_params, :jsonb

    add_column :images, :external_source, :string
    add_column :images, :external_id,     :string
    add_column :images, :author,          :string
    add_column :images, :license,         :string

    add_index :images, :external_source, where: "external_source IS NOT NULL"
    add_index :images, [ :external_source, :external_id ],
              unique: true,
              where: "external_source IS NOT NULL AND external_id IS NOT NULL",
              name: "index_images_on_external_source_and_external_id"

    reversible do |dir|
      dir.up do
        execute <<~SQL
          UPDATE images SET external_source = 'wikidata'
          WHERE external_source IS NULL AND url IS NOT NULL
        SQL
      end
    end
  end
end
