class HomeController < ApplicationController
  allow_unauthenticated_access only: %i[ start ]
  skip_before_action :require_email_verified

  def start
    @default_set = ImageSet.default if authenticated?
  end
end
