json.extract! guess, :id, :game_id, :image_id, :latitude, :longitude, :created_at, :updated_at
json.url guess_url(guess, format: :json)
json.answer do
  json.latitude guess.image.latitude
  json.longitude guess.image.longitude
end
