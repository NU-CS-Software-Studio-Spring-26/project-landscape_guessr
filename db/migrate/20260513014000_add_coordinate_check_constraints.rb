class AddCoordinateCheckConstraints < ActiveRecord::Migration[8.1]
  def up
    add_check_constraint :images,
      "latitude IS NULL OR (latitude >= -90 AND latitude <= 90)",
      name: "chk_images_latitude_range",
      validate: false

    add_check_constraint :images,
      "longitude IS NULL OR (longitude >= -180 AND longitude <= 180)",
      name: "chk_images_longitude_range",
      validate: false

    add_check_constraint :image_set_items,
      "latitude IS NULL OR (latitude >= -90 AND latitude <= 90)",
      name: "chk_image_set_items_latitude_range",
      validate: false

    add_check_constraint :image_set_items,
      "longitude IS NULL OR (longitude >= -180 AND longitude <= 180)",
      name: "chk_image_set_items_longitude_range",
      validate: false
  end

  def down
    remove_check_constraint :image_set_items, name: "chk_image_set_items_longitude_range"
    remove_check_constraint :image_set_items, name: "chk_image_set_items_latitude_range"
    remove_check_constraint :images, name: "chk_images_longitude_range"
    remove_check_constraint :images, name: "chk_images_latitude_range"
  end
end
