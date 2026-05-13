class AddTokenToChallenges < ActiveRecord::Migration[8.1]
  # Historical no-op. Earlier in this branch's lifetime CreateChallenges
  # didn't include `token`, so this migration added it. CreateChallenges
  # was later edited to include `token` directly, which left this one as
  # a duplicate that would `PG::DuplicateColumn` on any fresh
  # `db:migrate`. Environments that already recorded this version as up
  # (Heroku, team devs) keep skipping it; fresh setups now succeed.
  def change
  end
end
