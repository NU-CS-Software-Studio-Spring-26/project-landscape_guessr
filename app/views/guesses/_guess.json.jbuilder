json.extract! guess, :id, :game_id, :image_id, :latitude, :longitude, :created_at, :updated_at
json.url guess_url(guess, format: :json)
json.answer do
  gi = guess.game.game_images.find { |gi| gi.image_id == guess.image_id }
  json.latitude  gi&.answer_lat || guess.image.latitude
  json.longitude gi&.answer_lng || guess.image.longitude
end
