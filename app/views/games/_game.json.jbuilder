json.extract! game, :id, :status, :score, :completed_at, :created_at, :updated_at
json.url game_url(game, format: :json)
