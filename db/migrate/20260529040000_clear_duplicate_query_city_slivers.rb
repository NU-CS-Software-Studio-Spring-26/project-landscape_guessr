class ClearDuplicateQueryCitySlivers < ActiveRecord::Migration[8.1]
  # The old Region boundary fetch built a duplicated query when a city's admin1
  # ancestor shared its name ("Tokyo, Tokyo, Japan", "Beijing, Beijing, China").
  # Nominatim returned a street ADDRESS (a Point) for that, so the code fell
  # through to a reverse-geocode sliver — Tokyo/Beijing/Shanghai/Berlin/São
  # Paulo/Bangkok/Osaka/Kyoto/Dubai all stored a 2-6km ward as their "boundary".
  #
  # The query is now deduped, but rows that already cached a sliver won't
  # re-fetch (a boundary is present). Clear those so they lazily re-fetch with
  # the fixed code. Targets ONLY slivers (bbox < ~20km) under a same-named
  # admin1, so correct boundaries — including any this app already re-fetched —
  # are left untouched. No-op on a fresh DB (city boundaries are fetched lazily
  # at runtime, never seeded).
  SLIVER_SPAN_DEG = 20.0 / 111.0

  def up
    cleared = 0
    Region.where(admin_level: "city").where.not(boundary: nil).find_each do |city|
      next unless city.min_lat && city.max_lat && city.min_lng && city.max_lng
      next if [ city.max_lat - city.min_lat, city.max_lng - city.min_lng ].max >= SLIVER_SPAN_DEG

      anc = city.parent
      seen = []
      shares_admin1_name = false
      while anc && !seen.include?(anc.id)
        seen << anc.id
        if anc.admin_level == "admin1" && anc.normalized_name == city.normalized_name
          shares_admin1_name = true
          break
        end
        anc = anc.parent
      end
      next unless shares_admin1_name

      city.update_columns(boundary: nil)
      cleared += 1
    end
    say "cleared #{cleared} duplicate-query city slivers (they re-fetch lazily)"
  end

  def down
    # No-op: boundaries re-fetch lazily; the old slivers aren't worth restoring.
  end
end
