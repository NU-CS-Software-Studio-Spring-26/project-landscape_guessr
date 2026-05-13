class RemoveStaleColumnsFromChallenges < ActiveRecord::Migration[8.1]
  # The committed version of CreateChallenges never adds challengee_id or
  # status, so on any environment that ran the migrations in order these
  # columns don't exist and remove_column would raise. Guard each removal
  # so the migration is a no-op on clean environments and only cleans up
  # legacy databases where the columns somehow exist.
  def change
    remove_column :challenges, :challengee_id, :bigint if column_exists?(:challenges, :challengee_id)
    remove_column :challenges, :status,        :string if column_exists?(:challenges, :status)
  end
end
