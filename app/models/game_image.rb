class GameImage < ApplicationRecord
  belongs_to :game
  belongs_to :image

  def answer_lat
    answer_latitude&.to_f || image.latitude&.to_f
  end

  def answer_lng
    answer_longitude&.to_f || image.longitude&.to_f
  end
end
