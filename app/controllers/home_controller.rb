class HomeController < ApplicationController
  allow_unauthenticated_access only: %i[ start about ]

  def start
    if authenticated?
      @default_set = ImageSet.default
    else
      @game_count  = Game.count
      @image_count = Image.count
    end
  end

  def about
  end
end
