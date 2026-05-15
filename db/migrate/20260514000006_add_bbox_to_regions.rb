class AddBboxToRegions < ActiveRecord::Migration[8.1]
  def change
    add_column :regions, :min_lat, :float
    add_column :regions, :max_lat, :float
    add_column :regions, :min_lng, :float
    add_column :regions, :max_lng, :float
  end
end
