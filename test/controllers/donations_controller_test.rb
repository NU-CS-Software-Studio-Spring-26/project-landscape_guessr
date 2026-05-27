require "test_helper"

class DonationsControllerTest < ActionDispatch::IntegrationTest
  test "footer renders Support us button" do
    get root_url
    assert_response :success

    assert_select "form[action='#{donation_path}'][method='post']" do
      assert_select "[data-turbo='false']"
      assert_select "button[type=submit]", text: "Support us"
    end
  end

  test "create redirects to Stripe checkout when configured" do
    fake_session = Struct.new(:url).new("https://checkout.stripe.com/pay/test_session")

    with_stripe_secret_key("sk_test_123") do
      stub_class_method(Stripe::Checkout::Session, :create, ->(*) { fake_session }) do
        post donation_url
      end
    end

    assert_redirected_to "https://checkout.stripe.com/pay/test_session"
    assert_response :see_other
  end

  test "create redirects safely when Stripe is not configured" do
    with_stripe_secret_key(nil) do
      post donation_url
    end

    assert_redirected_to root_url
    assert_equal "Donations are not available right now.", flash[:alert]
  end

  test "success page renders with test-mode messaging" do
    get success_donation_url
    assert_response :success
    assert_match(/test-mode/i, response.body)
    assert_select "main a[href='#{root_path}']", text: "Back to homepage"
  end

  test "cancel page renders with canceled messaging" do
    get cancel_donation_url
    assert_response :success
    assert_match(/canceled/i, response.body)
    assert_select "main a[href='#{root_path}']", text: "Back to homepage"
  end

  private

    def with_stripe_secret_key(value)
      previous = ENV["STRIPE_SECRET_KEY"]
      ENV["STRIPE_SECRET_KEY"] = value
      yield
    ensure
      ENV["STRIPE_SECRET_KEY"] = previous
    end
end
