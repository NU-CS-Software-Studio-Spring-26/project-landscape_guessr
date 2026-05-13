class HomeController < ApplicationController
  allow_unauthenticated_access only: %i[ start scoring ]

  def start
    @default_set = ImageSet.default if authenticated?
  end

  def scoring
  end
end
