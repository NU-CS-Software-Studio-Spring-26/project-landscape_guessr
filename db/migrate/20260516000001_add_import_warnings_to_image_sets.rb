class AddImportWarningsToImageSets < ActiveRecord::Migration[8.1]
  # Partial-failure tracking for AI imports. Per-type fan-out can have
  # some types succeed and others fail (WDQS timeout on huge classes,
  # 502s past retries, etc). Surface those on the set's show page so
  # the user knows what's missing and can refine or retry.
  def change
    add_column :image_sets, :import_warnings, :jsonb
  end
end
