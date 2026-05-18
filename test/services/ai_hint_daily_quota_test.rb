# frozen_string_literal: true

require "test_helper"

class AiHintDailyQuotaTest < ActiveSupport::TestCase
  setup do
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache.lookup_store(:memory_store)
  end

  teardown do
    Rails.cache = @previous_cache
  end

  test "for user tracks count up to limit" do
    quota = AiHintDailyQuota.for(user: users(:alice))

    assert_equal 0, quota.used
    assert_not quota.exceeded?
    AiHintDailyQuota::LIMIT.times { quota.record! }
    assert_equal AiHintDailyQuota::LIMIT, quota.used
    assert quota.exceeded?
    assert_equal({ quota_used: AiHintDailyQuota::LIMIT, quota_limit: AiHintDailyQuota::LIMIT }, quota.as_json)
  end

  test "guest identities are isolated" do
    guest_a = AiHintDailyQuota.for(user: nil, guest_session_id: "session-a")
    guest_b = AiHintDailyQuota.for(user: nil, guest_session_id: "session-b")

    AiHintDailyQuota::LIMIT.times { guest_a.record! }

    assert guest_a.exceeded?
    assert_not guest_b.exceeded?
  end

  test "charge_generation! counts once per image and tier per day" do
    quota = AiHintDailyQuota.for(user: users(:alice))

    quota.charge_generation!(image_id: 42, tier: 2)
    quota.charge_generation!(image_id: 42, tier: 2)

    assert_equal 1, quota.used
    assert quota.charged?(42, 2)
    assert_not quota.charged?(42, 3)
  end

  test "blocked_for_new_charge allows retry when already charged" do
    quota = AiHintDailyQuota.for(user: users(:alice))
    AiHintDailyQuota::LIMIT.times { quota.record! }
    quota.charge_generation!(image_id: 7, tier: 1)

    assert quota.exceeded?
    assert_not quota.blocked_for_new_charge?(7, 1)
    assert quota.blocked_for_new_charge?(8, 1)
  end

  test "user and guest quotas are isolated" do
    user_quota = AiHintDailyQuota.for(user: users(:alice))
    guest_quota = AiHintDailyQuota.for(user: nil, guest_session_id: "guest")

    AiHintDailyQuota::LIMIT.times { user_quota.record! }

    assert user_quota.exceeded?
    assert_not guest_quota.exceeded?
  end
end
