class RemoveStaleColumnsFromChallenges < ActiveRecord::Migration[8.1]
  def change
    remove_column :challenges, :challengee_id, :bigint
    remove_column :challenges, :status, :string
  end
end
