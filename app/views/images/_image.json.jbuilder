json.extract! image, :id, :url, :latitude, :longitude, :title, :created_at, :updated_at
json.url image_url(image, format: :json)
