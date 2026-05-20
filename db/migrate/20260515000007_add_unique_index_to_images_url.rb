class AddUniqueIndexToImagesUrl < ActiveRecord::Migration[8.1]
  # Two callers — WikidataImporter#insert_slice! and the upload path —
  # both insert by URL, and both have to deduplicate against existing
  # rows themselves. Until now there was nothing stopping a race (two
  # concurrent imports, a retry_import that re-runs while the original
  # job is still finishing) from producing duplicate Image rows for
  # the same URL. The pre-query dedup helps but doesn't close the gap.
  #
  # The index is unique only when url IS NOT NULL because uploaded
  # images (Active Storage) have a null url and would all collide.
  #
  # disable_ddl_transaction! is required for CREATE INDEX CONCURRENTLY
  # (it can't run inside a transaction). The dedup DELETE is split into
  # its own implicit transaction (default for non-DDL statements).
  disable_ddl_transaction!

  def up
    # Repoint dependent rows from each duplicate Image to the canonical
    # one (lowest id per URL). Without this the DELETE below would hit
    # a foreign-key violation from any image_set_items / game_images /
    # challenge_images / guesses pointing at the duplicate. Doing the
    # repoint is safer than relying on "AI imports haven't linked yet"
    # — the original assumption was wrong: a user could have manually
    # added the same Commons URL to a private set and seeded join rows
    # before this migration runs.
    execute <<~SQL.squish
      WITH dup_map AS (
        SELECT id AS dup_id,
               FIRST_VALUE(id) OVER (PARTITION BY url ORDER BY id) AS keep_id
        FROM images
        WHERE url IS NOT NULL
      )
      UPDATE image_set_items SET image_id = dup_map.keep_id
      FROM dup_map
      WHERE image_set_items.image_id = dup_map.dup_id
        AND dup_map.dup_id <> dup_map.keep_id
    SQL
    execute <<~SQL.squish
      WITH dup_map AS (
        SELECT id AS dup_id,
               FIRST_VALUE(id) OVER (PARTITION BY url ORDER BY id) AS keep_id
        FROM images
        WHERE url IS NOT NULL
      )
      UPDATE game_images SET image_id = dup_map.keep_id
      FROM dup_map
      WHERE game_images.image_id = dup_map.dup_id
        AND dup_map.dup_id <> dup_map.keep_id
    SQL
    execute <<~SQL.squish
      WITH dup_map AS (
        SELECT id AS dup_id,
               FIRST_VALUE(id) OVER (PARTITION BY url ORDER BY id) AS keep_id
        FROM images
        WHERE url IS NOT NULL
      )
      UPDATE challenge_images SET image_id = dup_map.keep_id
      FROM dup_map
      WHERE challenge_images.image_id = dup_map.dup_id
        AND dup_map.dup_id <> dup_map.keep_id
    SQL
    execute <<~SQL.squish
      WITH dup_map AS (
        SELECT id AS dup_id,
               FIRST_VALUE(id) OVER (PARTITION BY url ORDER BY id) AS keep_id
        FROM images
        WHERE url IS NOT NULL
      )
      UPDATE guesses SET image_id = dup_map.keep_id
      FROM dup_map
      WHERE guesses.image_id = dup_map.dup_id
        AND dup_map.dup_id <> dup_map.keep_id
    SQL
    # After the repoint, intra-table uniqueness can be re-violated
    # (e.g. two ImageSetItems in the same set both pointing at the dup
    # and keep — now both at keep). Resolve by deleting the duplicates;
    # the unique index on (image_set_id, image_id) would block the
    # subsequent DELETE FROM images otherwise.
    execute <<~SQL.squish
      DELETE FROM image_set_items USING image_set_items isi2
      WHERE image_set_items.image_set_id = isi2.image_set_id
        AND image_set_items.image_id = isi2.image_id
        AND image_set_items.id > isi2.id
    SQL
    # Now safe to delete the duplicate Image rows.
    execute <<~SQL.squish
      DELETE FROM images
      WHERE id IN (
        SELECT id FROM (
          SELECT id, ROW_NUMBER() OVER (PARTITION BY url ORDER BY id) AS rn
          FROM images
          WHERE url IS NOT NULL
        ) ranked
        WHERE rn > 1
      )
    SQL
    # CONCURRENTLY avoids the ACCESS EXCLUSIVE lock that a normal
    # CREATE INDEX takes — on a non-trivial images table this would
    # block concurrent imports / uploads for the duration of the build.
    add_index :images, :url, unique: true, where: "url IS NOT NULL",
              algorithm: :concurrently
  end

  def down
    remove_index :images, :url, algorithm: :concurrently
  end
end
