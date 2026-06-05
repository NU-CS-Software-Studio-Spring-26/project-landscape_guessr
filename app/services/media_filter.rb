# Shared "is this file actually a photograph?" filter, used by every image
# source so a category/search that happens to contain maps, relief diagrams,
# satellite imagery or schematics doesn't seed those into a guessing set.
#
# Both WikidataImporter (P18 / Wikipedia lead images) and CommonsImporter
# (CirrusSearch results) run filenames through this — Wikidata used to be the
# only one with the filter, so Commons categories leaked the odd relief-map
# `.jpg`. The patterns live here as the single source of truth (db/seeds.rb
# keeps its own copy for the seed-only import path).
module MediaFilter
  # No \b word boundaries — Ruby's \b treats `_` as a word char, so \bMODIS\b
  # fails to match "MODIS_satellite.jpg". Do not re-add \b without testing
  # against real filenames.
  NON_PHOTO_PATTERNS = [
    /ASTER|MODIS|Landsat|LANDSAT|Sentinel|MISR|Messtischblatt/i,
    /_map[._]|location[_\s-]map|relief[_\s-]map|system[_\s-]map/i,
    /topographic|schematic|Harper.?s[_\s-]New/i
  ].freeze

  # A URL or bare filename that passes the "looks like a photo" sniff test.
  # Drops obvious maps, schematics, and satellite imagery; only keeps jpg/png.
  def self.photo_url?(url)
    return false if url.blank? || url.length > 500
    return false unless url.match?(/\.(jpe?g|png)\z/i)
    decoded = URI.decode_www_form_component(url.split("/").last.to_s)
    NON_PHOTO_PATTERNS.none? { |p| decoded.match?(p) }
  end
end
