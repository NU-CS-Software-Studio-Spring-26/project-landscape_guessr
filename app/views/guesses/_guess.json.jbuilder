json.extract! guess, :id, :game_id, :image_id, :latitude, :longitude, :created_at, :updated_at
json.url guess_url(guess, format: :json)
json.answer do
  gi = guess.game.game_images.find { |gi| gi.image_id == guess.image_id }
  json.latitude  gi&.answer_lat || guess.image.latitude
  json.longitude gi&.answer_lng || guess.image.longitude
end

if (challenge = guess.game.challenge)
  other_guesses = Guess
    .joins(:game)
    .where(games: { challenge_id: challenge.id })
    .where(image_id: guess.image_id)
    .where.not(game_id: guess.game_id)
    .includes(game: :user)

  json.other_guesses other_guesses do |og|
    json.username og.game.user.username
    json.latitude og.latitude
    json.longitude og.longitude
  end
else
  json.other_guesses []
end
