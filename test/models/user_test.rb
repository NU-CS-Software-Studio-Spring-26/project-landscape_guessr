require "test_helper"

class UserTest < ActiveSupport::TestCase
  setup do
    @attrs = { email_address: "new@example.com", username: "newuser", password: "password123" }
  end

  test "valid attributes save" do
    assert User.new(@attrs).save
  end

  # Email
  test "requires email" do
    user = User.new(@attrs.merge(email_address: ""))
    assert_not user.valid?
    assert user.errors[:email_address].present?
  end

  test "rejects malformed email" do
    user = User.new(@attrs.merge(email_address: "not-an-email"))
    assert_not user.valid?
    assert user.errors[:email_address].present?
  end

  test "rejects duplicate email (case-insensitive via normalization)" do
    User.create!(@attrs)
    dup = User.new(@attrs.merge(email_address: "NEW@example.com", username: "different"))
    assert_not dup.valid?
    assert dup.errors[:email_address].present?
  end

  test "duplicate-email error is masked to avoid enumeration" do
    User.create!(@attrs)
    dup = User.new(@attrs.merge(username: "different"))
    dup.valid?
    assert_includes dup.errors[:email_address], "is invalid"
  end

  # Username
  test "requires username" do
    user = User.new(@attrs.merge(username: ""))
    assert_not user.valid?
    assert user.errors[:username].present?
  end

  test "rejects username shorter than 3 chars" do
    user = User.new(@attrs.merge(username: "ab"))
    assert_not user.valid?
    assert user.errors[:username].present?
  end

  test "rejects username longer than 20 chars" do
    user = User.new(@attrs.merge(username: "a" * 21))
    assert_not user.valid?
    assert user.errors[:username].present?
  end

  test "rejects username with disallowed characters" do
    user = User.new(@attrs.merge(username: "has spaces"))
    assert_not user.valid?
    assert user.errors[:username].present?
  end

  test "rejects duplicate username case-insensitively" do
    User.create!(@attrs)
    dup = User.new(@attrs.merge(email_address: "other@example.com", username: "NewUser"))
    assert_not dup.valid?
    assert dup.errors[:username].present?
  end

  # OAuth-pending username (created via Google sign-in, no username yet)
  test "user with no username but a connected_service is valid" do
    user = User.new(@attrs.merge(username: nil))
    user.connected_services.build(provider: "google_oauth2", uid: "abc")
    assert user.valid?
  end

  test "user with no username and no connected_service is invalid" do
    user = User.new(@attrs.merge(username: nil))
    assert_not user.valid?
    assert user.errors[:username].present?
  end

  test "pending_username_setup? true only when username blank AND has connected_service" do
    user = User.new(@attrs.merge(username: nil))
    user.connected_services.build(provider: "google_oauth2", uid: "abc")
    assert user.pending_username_setup?

    user2 = User.new(@attrs)
    assert_not user2.pending_username_setup?
  end

  # Password
  test "rejects password shorter than 8 chars" do
    user = User.new(@attrs.merge(password: "short"))
    assert_not user.valid?
    assert user.errors[:password].present?
  end

  # find_by_login
  test "find_by_login finds by email" do
    user = User.create!(@attrs)
    assert_equal user, User.find_by_login("new@example.com")
    assert_equal user, User.find_by_login("NEW@example.com")
  end

  test "find_by_login finds by username case-insensitively" do
    user = User.create!(@attrs)
    assert_equal user, User.find_by_login("newuser")
    assert_equal user, User.find_by_login("NEWUSER")
  end

  test "find_by_login returns nil for unknown" do
    assert_nil User.find_by_login("nope")
    assert_nil User.find_by_login("nope@example.com")
    assert_nil User.find_by_login("")
    assert_nil User.find_by_login(nil)
  end
end
