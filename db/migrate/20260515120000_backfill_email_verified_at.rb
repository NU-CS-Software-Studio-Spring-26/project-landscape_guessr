class BackfillEmailVerifiedAt < ActiveRecord::Migration[8.0]
  def up
    # Mark every user that pre-existed the email-verification feature as
    # verified, so they don't get locked out of features gated on it.
    execute(<<~SQL.squish)
      UPDATE users
      SET email_verified_at = created_at
      WHERE email_verified_at IS NULL
    SQL
  end

  def down
    # Irreversible: we can't distinguish backfilled users from genuinely-verified ones.
  end
end
