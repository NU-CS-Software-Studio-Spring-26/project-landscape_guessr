module Sessions
  class OmniAuthsController < ApplicationController
    allow_unauthenticated_access only: %i[ create failure ]
    skip_before_action :require_username_set, only: %i[ create failure ]

    def create
      auth = request.env["omniauth.auth"]
      return redirect_failure("Sign-in failed.") if auth.blank?

      provider = auth.provider.to_s
      uid      = auth.uid.to_s
      email    = auth.info&.email.to_s.downcase.presence
      verified = auth.info&.email_verified
      verified = auth.extra&.id_info&.dig("email_verified") if verified.nil?

      service = ConnectedService.find_by(provider: provider, uid: uid)
      if service
        sign_in_and_redirect(service.user)
        return
      end

      return redirect_failure("Google did not provide an email address.") unless email
      return redirect_failure("Google did not confirm that email is yours.") unless verified

      ActiveRecord::Base.transaction do
        user = User.find_by(email_address: email) || build_oauth_user(email)
        user.connected_services.build(provider: provider, uid: uid, email: email)
        user.save!
        sign_in_and_redirect(user)
      end
    rescue ActiveRecord::RecordInvalid => e
      Rails.logger.warn("[oauth] callback failed: #{e.record.errors.full_messages.to_sentence}")
      redirect_failure("Sign-in failed: #{e.record.errors.full_messages.first}")
    end

    def failure
      redirect_failure(params[:message].presence || "Sign-in cancelled or failed.")
    end

    private
      def build_oauth_user(email)
        password = SecureRandom.hex(24)
        User.new(email_address: email, password: password, password_confirmation: password)
      end

      def sign_in_and_redirect(user)
        start_new_session_for(user)
        if user.pending_username_setup?
          redirect_to setup_username_profile_path, notice: "Welcome! Pick a username to finish setting up."
        else
          redirect_to after_authentication_url, notice: "Signed in."
        end
      end

      def redirect_failure(message)
        redirect_to new_session_path, alert: message
      end
  end
end
