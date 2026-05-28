# Looks up scalar Wikidata properties (currently just P373 — "Commons
# category") via a small SPARQL query, cached for 7 days. Used by
# `CommonsCategoryResolver` to bridge a Wikidata Q-ID to a Commons
# category name (e.g. Q243 "Eiffel Tower" → "Eiffel Tower").
#
# P373 is the canonical bridge between Wikidata items and Wikimedia
# Commons categories. Verified 12/12 hit rate in our research, including
# tricky ones like Q4348747 "Millennium Park, Chicago".
class WikidataPropertyLookup
  CACHE_TTL = 7.days

  def self.commons_category_for(qid)
    return nil if qid.blank? || qid !~ /\AQ\d+\z/
    Rails.cache.fetch("wd:p373:#{qid}", expires_in: CACHE_TTL) do
      fetch_commons_category(qid)
    end
  end

  def self.fetch_commons_category(qid)
    sparql = "SELECT ?cat WHERE { wd:#{qid} wdt:P373 ?cat }"
    rows = WikidataImporter.run_query(sparql)
    rows&.first&.dig("cat", "value")
  rescue StandardError => e
    Rails.logger.warn "[wd p373] #{qid}: #{e.class}: #{e.message.slice(0, 200)}"
    nil
  end

  # P625 coordinate of an item → { lat:, lng: } or nil. Used to anchor a
  # `nearcoord:` filter for region-less Commons "subject" prompts (e.g.
  # "Mount Fuji photos") so deepcategory pollution and ungeotagged files
  # get pruned to actual photos taken near the subject.
  def self.coordinate_for(qid)
    return nil if qid.blank? || qid !~ /\AQ\d+\z/
    Rails.cache.fetch("wd:p625:#{qid}", expires_in: CACHE_TTL) do
      fetch_coordinate(qid)
    end
  end

  # Wikidata returns P625 as a WKT literal "Point(<lng> <lat>)".
  def self.fetch_coordinate(qid)
    rows = WikidataImporter.run_query("SELECT ?coord WHERE { wd:#{qid} wdt:P625 ?coord } LIMIT 1")
    wkt = rows&.first&.dig("coord", "value")
    return nil if wkt.blank?
    m = wkt.match(/Point\(\s*(-?\d+(?:\.\d+)?)\s+(-?\d+(?:\.\d+)?)\s*\)/i)
    return nil unless m
    { lat: m[2].to_f, lng: m[1].to_f }
  rescue StandardError => e
    Rails.logger.warn "[wd p625] #{qid}: #{e.class}: #{e.message.slice(0, 200)}"
    nil
  end
end
