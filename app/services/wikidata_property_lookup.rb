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
end
