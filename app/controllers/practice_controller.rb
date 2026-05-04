class PracticeController < ApplicationController
  allow_unauthenticated_access only: %i[ show ]

  def show
    default_set = ImageSet.default
    @image = default_set&.images&.order("RANDOM()")&.first || Image.order("RANDOM()").first

    if @image.nil?
      redirect_to images_path, alert: "No images available. Seed some first."
    end
  end
end
