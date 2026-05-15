class AddTokenToChallenges < ActiveRecord::Migration[8.1]
  # The committed version of CreateChallenges already adds the `token`
  # column and unique index, so this migration would raise
  # PG::DuplicateColumn on any clean run. Guard the operations so the
  # migration is a no-op on clean environments and only fills in `token`
  # for legacy databases where it's missing.
  def change
    unless column_exists?(:challenges, :token)
      add_column :challenges, :token, :string, null: false, default: ""
      add_index  :challenges, :token, unique: true
    end
  end
end
