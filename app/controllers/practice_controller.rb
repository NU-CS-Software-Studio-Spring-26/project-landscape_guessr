class PracticeController < ApplicationController
  def show
    @image = Image.order("RANDOM()").first

    if @image.nil?
      redirect_to images_path, alert: "No images available. Seed some first."
    end
  end
end
