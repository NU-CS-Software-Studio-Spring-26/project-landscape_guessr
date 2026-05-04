class AddUsernameToUsers < ActiveRecord::Migration[8.1]
  def up
    add_column :users, :username, :string

    User.reset_column_information
    User.find_each do |user|
      base = user.email_address.to_s.split("@").first.to_s
        .gsub(/[^a-zA-Z0-9_-]/, "_")
        .downcase
        .first(20)
      base = "user" if base.length < 3

      candidate = base
      if User.where("LOWER(username) = ?", candidate.downcase).where.not(id: user.id).exists?
        candidate = "#{base}_#{user.id}".first(30)
      end
      user.update_column(:username, candidate)
    end

    change_column_null :users, :username, false
    add_index :users, "LOWER(username)", unique: true, name: "index_users_on_lower_username"
  end

  def down
    remove_index :users, name: "index_users_on_lower_username"
    remove_column :users, :username
  end
end
