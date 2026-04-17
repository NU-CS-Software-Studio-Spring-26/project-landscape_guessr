class CreateImages < ActiveRecord::Migration[8.1]
  def change
    create_table :images do |t|
      t.string :url
      t.decimal :latitude
      t.decimal :longitude
      t.string :title

      t.timestamps
    end
  end
end
