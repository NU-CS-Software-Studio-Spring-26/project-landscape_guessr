class AddTokenToChallenges < ActiveRecord::Migration[8.1]
  def change
    add_column :challenges, :token, :string, null: false, default: ""
    add_index  :challenges, :token, unique: true
  end
end
