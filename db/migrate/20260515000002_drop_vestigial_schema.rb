class DropVestigialSchema < ActiveRecord::Migration[8.1]
  # `connected_services` table and `users.email_verified_at` column entered
  # the schema with no model, no callers, no creating migration in
  # db/migrate/. Dropping them so a fresh schema doesn't carry unowned state
  # that future readers will treat as load-bearing.
  def up
    drop_table :connected_services, if_exists: true
    remove_column :users, :email_verified_at, :datetime, if_exists: true
  end

  def down
    add_column :users, :email_verified_at, :datetime
    create_table :connected_services do |t|
      t.string :provider, null: false
      t.string :uid, null: false
      t.string :email
      t.references :user, null: false, foreign_key: true
      t.timestamps
      t.index [ :provider, :uid ], unique: true
    end
  end
end
