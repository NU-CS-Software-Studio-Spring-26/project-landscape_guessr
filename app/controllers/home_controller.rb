class HomeController < ApplicationController
  allow_unauthenticated_access only: %i[ start ]

  def start
  end
end
