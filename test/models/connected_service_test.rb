require "test_helper"

class ConnectedServiceTest < ActiveSupport::TestCase
  setup do
    @user = users(:alice)
  end

  test "valid attributes save" do
    cs = @user.connected_services.build(provider: "google_oauth2", uid: "abc123", email: "a@b.com")
    assert cs.valid?
  end

  test "requires provider" do
    cs = @user.connected_services.build(uid: "abc123")
    assert_not cs.valid?
  end

  test "requires uid" do
    cs = @user.connected_services.build(provider: "google_oauth2")
    assert_not cs.valid?
  end

  test "uid is unique per provider" do
    @user.connected_services.create!(provider: "google_oauth2", uid: "abc123")
    other = users(:bob).connected_services.build(provider: "google_oauth2", uid: "abc123")
    assert_not other.valid?
  end

  test "same uid is allowed across different providers" do
    @user.connected_services.create!(provider: "google_oauth2", uid: "abc123")
    other = @user.connected_services.build(provider: "github", uid: "abc123")
    assert other.valid?
  end

  test "deleting a user destroys their connected services" do
    @user.connected_services.create!(provider: "google_oauth2", uid: "abc123")
    assert_difference -> { ConnectedService.count }, -1 do
      @user.destroy
    end
  end
end
