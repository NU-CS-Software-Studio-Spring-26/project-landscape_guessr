class HomeController < ApplicationController
  allow_unauthenticated_access only: %i[ start ]

  def start
    @default_set = ImageSet.default
  end
end
