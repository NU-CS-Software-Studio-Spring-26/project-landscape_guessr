# frozen_string_literal: true

# Tracks how many new AI hint generations a caller may trigger per calendar day.
# Cached ready hints and pending polls do not consume quota.
class AiHintDailyQuota
  LIMIT = 100

  LIMIT_EXCEEDED_MESSAGE = <<~MSG.squish
    Daily AI hint limit reached (#{LIMIT} per day). Try again tomorrow or use
    radius and location hints.
  MSG

  def self.for(user:, guest_session_id: nil)
    new(identity_for(user: user, guest_session_id: guest_session_id))
  end

  def self.identity_for(user:, guest_session_id: nil)
    if user
      "user:#{user.id}"
    else
      "guest:#{guest_session_id}"
    end
  end

  def initialize(identity)
    @identity = identity
  end

  def used
    count
  end

  def exceeded?
    used >= LIMIT
  end

  def charged?(image_id, tier)
    Rails.cache.exist?(charge_cache_key(image_id, tier))
  end

  def blocked_for_new_charge?(image_id, tier)
    exceeded? && !charged?(image_id, tier)
  end

  def charge_generation!(image_id:, tier:)
    return if charged?(image_id, tier)

    record!
    Rails.cache.write(charge_cache_key(image_id, tier), true, expires_in: expires_in)
  end

  def record!
    Rails.cache.increment(cache_key, 1, initial: 0, expires_in: expires_in)
  end

  def as_json
    { quota_used: used, quota_limit: LIMIT }
  end

  private

  def count
    Rails.cache.read(cache_key).to_i
  end

  def cache_key
    "ai_hint_daily_quota:#{@identity}:#{Date.current}"
  end

  def charge_cache_key(image_id, tier)
    "ai_hint_daily_quota_charge:#{@identity}:#{Date.current}:#{image_id}:#{tier}"
  end

  def expires_in
    Time.current.end_of_day - Time.current
  end
end
