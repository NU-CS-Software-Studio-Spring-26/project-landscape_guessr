class HomeController < ApplicationController
  allow_unauthenticated_access only: %i[ start about legal scoring ]
  skip_before_action :require_email_verified

  def start
    if authenticated?
      @default_set = ImageSet.default
      @saved_practice_set = Current.user.image_sets.find_by(name: ImageSet::SAVED_FOR_PRACTICE_NAME)
    else
      @game_count  = Game.count
      @image_count = Image.count
    end
  end

  def about
  end

  def legal
  end

  def scoring
  end
end
