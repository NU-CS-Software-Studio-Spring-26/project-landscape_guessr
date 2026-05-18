class AddPopulationToRegions < ActiveRecord::Migration[8.1]
  def change
    add_column :regions, :population, :integer
  end
end
