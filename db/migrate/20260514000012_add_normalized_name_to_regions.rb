class AddNormalizedNameToRegions < ActiveRecord::Migration[8.1]
  # Adds a `normalized_name` column populated from `name` via the same
  # prefix/suffix-stripping rules used at app level (Region.normalize_admin_name).
  # Indexed for fast app-level dedup when lazy-creating regions from geocoder
  # output: at insert time, the controller asks
  #   "is there already a row under this parent + admin_level whose normalized
  #    name matches the geocoder's name?"
  # and reuses the existing row if yes.
  #
  # Why no unique index here:
  # - There are legitimate same-normalized-name pairs in GeoNames (e.g. Peru's
  #   "Lima Province" vs "Lima region" — different admin entities, same English
  #   shorthand). Forcing uniqueness would lose information.
  # - There are also legitimate same-RAW-name pairs (e.g. multiple Vietnamese
  #   "Huyện Châu Thành" districts under the same province, each with its own
  #   GeoNames iso_code). So (admin_level, parent_id, name) is also non-unique.
  # We accept a rare race window for lazy-create instead of constraining data.
  def up
    add_column :regions, :normalized_name, :string

    backfill_sql = <<~SQL.squish
      UPDATE regions SET normalized_name = #{normalize_sql("name")}
    SQL
    execute(backfill_sql)

    add_index :regions, [ :parent_id, :admin_level, :normalized_name ],
              name: "index_regions_on_parent_level_normname"
  end

  def down
    remove_index :regions, name: "index_regions_on_parent_level_normname"
    remove_column :regions, :normalized_name
  end

  private

  # Inlined here (not calling Region.normalize_admin_name_sql) so the migration
  # is self-contained and won't break if the model's normalize rules change
  # later. Must stay in sync with Region.normalize_admin_name (Ruby version).
  def normalize_sql(column)
    prefix = "(state of|land|province of|region of|kingdom of|republic of|" \
             "autonomous city of|special capital region of|capital district of|" \
             "federal district of|metropolitan region of|metro|greater|" \
             "estado de|provincia de|departamento de)"
    suffix = "(county|province|state|region|department|voivodeship|prefecture|" \
             "district|territory|oblast|krai|governorate|emirate|" \
             "special capital region|metropolitan region|capital district|f\\.d\\.)"
    "regexp_replace(" \
      "regexp_replace(" \
        "regexp_replace(" \
          "lower(unaccent(#{column}))," \
          "'^#{prefix}\\s+', '', 'i'" \
        ")," \
        "'\\s+#{suffix}$', '', 'i'" \
      ")," \
      "'[^a-z0-9]+', '', 'g'" \
    ")"
  end
end
