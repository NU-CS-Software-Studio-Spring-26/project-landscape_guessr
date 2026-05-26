class DonationsController < ApplicationController
  allow_unauthenticated_access only: %i[ create success cancel ]
  skip_before_action :require_username_set
  skip_before_action :require_email_verified

  def create
    secret_key = ENV["STRIPE_SECRET_KEY"]

    unless secret_key.present?
      redirect_to root_path, alert: "Donations are not available right now."
      return
    end

    Stripe.api_key = secret_key

    session = Stripe::Checkout::Session.create(
      mode: "payment",
      line_items: [
        {
          price_data: {
            currency: "usd",
            product_data: {
              name: "Support Landscape Guessr hosting costs (demo)"
            },
            unit_amount: 300
          },
          quantity: 1
        }
      ],
      success_url: success_donation_url,
      cancel_url: cancel_donation_url
    )

    redirect_to session.url, allow_other_host: true, status: :see_other
  rescue Stripe::StripeError => e
    Rails.logger.error("Stripe error starting donation checkout: #{e.message}")
    redirect_to root_path, alert: "We couldn't start the donation checkout. Please try again later."
  end

  def success; end

  def cancel; end
end
