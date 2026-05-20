class AiUsage < ApplicationRecord
  belongs_to :user

  # Returns true iff this user has hit today's cap. Caller decides what
  # to do (render 429, suggest tomorrow, etc.).
  def self.exceeded?(user:, daily_limit:)
    today_count(user: user) >= daily_limit
  end

  # Atomic upsert + increment. Returns the new count after the bump.
  # Uses Postgres' INSERT ... ON CONFLICT to keep things race-safe
  # under concurrent web workers — without this, two parallel requests
  # could both read N, both write N+1, and the user gets one free call.
  def self.bump!(user:)
    rec = upsert_all(
      [ { user_id: user.id, day: Date.current, count: 1,
          created_at: Time.current, updated_at: Time.current } ],
      unique_by: [ :user_id, :day ],
      on_duplicate: Arel.sql("count = ai_usages.count + 1, updated_at = EXCLUDED.updated_at"),
      returning: [ :count ]
    )
    rec.rows.first&.first.to_i
  end

  def self.today_count(user:)
    where(user_id: user.id, day: Date.current).pick(:count).to_i
  end
end
