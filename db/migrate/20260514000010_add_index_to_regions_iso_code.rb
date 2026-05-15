class AddIndexToRegionsIsoCode < ActiveRecord::Migration[8.1]
  def change
    add_index :regions, :iso_code
  end
end
