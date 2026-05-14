class ImageRegion < ApplicationRecord
  belongs_to :image
  belongs_to :region
end
