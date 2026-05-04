class BackfillDefaultImageSet < ActiveRecord::Migration[8.1]
  def up
    # Create the system default set
    default_set_id = execute(<<~SQL).first["id"]
      INSERT INTO image_sets (name, user_id, visibility, is_system_default, created_at, updated_at)
      VALUES ('Default Landscapes', NULL, 'public', TRUE, NOW(), NOW())
      RETURNING id
    SQL

    # Link every existing image into the default set, copying its coords
    execute(<<~SQL)
      INSERT INTO image_set_items (image_set_id, image_id, latitude, longitude, created_at, updated_at)
      SELECT #{default_set_id}, id, latitude, longitude, NOW(), NOW()
      FROM images
      ON CONFLICT (image_set_id, image_id) DO NOTHING
    SQL

    # Point all existing games at the default set
    execute(<<~SQL)
      UPDATE games SET image_set_id = #{default_set_id}
      WHERE image_set_id IS NULL
    SQL

    # Snapshot answer coords for existing game_images from the image row
    execute(<<~SQL)
      UPDATE game_images gi
      SET answer_latitude  = i.latitude,
          answer_longitude = i.longitude
      FROM images i
      WHERE gi.image_id = i.id
        AND gi.answer_latitude IS NULL
    SQL
  end

  def down
    execute("UPDATE games SET image_set_id = NULL")
    execute("DELETE FROM image_set_items")
    execute("DELETE FROM image_sets WHERE is_system_default = TRUE")
  end
end
