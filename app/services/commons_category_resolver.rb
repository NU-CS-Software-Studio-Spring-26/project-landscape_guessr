require "net/http"
require "uri"
require "json"

# Resolves an AI-supplied topic Q-ID (and optional combined Q-ID) to a
# Wikimedia Commons category name suitable for `deepcategory:`. Uses
# Wikidata P373 ("Commons category") as the canonical bridge.
#
# Candidate order (first that EXISTS on Commons wins):
#   1. combined_qid's P373 — most specific (e.g. Q1130516 "Millennium Park,
#      Chicago" → "Millennium Park, Chicago")
#   2. "<topic category> in <region>" — the region-anchored category, which
#      is what makes "buildings in Boston" work. deepcategory on the generic
#      root P373 of "building" ("Buildings") can't expand its enormous tree
#      and returns ~1 hit; "Buildings in Boston" expands fine (~11k hits).
#   3. topic_qid's P373 — the bare subject category (e.g. "Mount Fuji"),
#      used for region-less subject prompts and already-specific topics.
#
# Each candidate is verified to actually exist on Commons before being
# returned — P373 occasionally points to renamed/merged categories.
class CommonsCategoryResolver
  API = URI("https://commons.wikimedia.org/w/api.php").freeze
  USER_AGENT = WikimediaUserAgent::STRING
  EXISTENCE_CACHE_TTL = 7.days

  # Returns a category name (without the "Category:" prefix) or nil.
  # `region_label` (e.g. "Boston") enables the region-anchored combined
  # category that fixes generic-topic prompts.
  def self.resolve(topic_qid: nil, combined_qid: nil, region_label: nil)
    candidates(topic_qid: topic_qid, combined_qid: combined_qid, region_label: region_label).each do |cat|
      return cat if category_exists?(cat)
    end
    nil
  end

  # Ordered, de-duped list of candidate category names to probe.
  def self.candidates(topic_qid:, combined_qid:, region_label:)
    list = []
    list << WikidataPropertyLookup.commons_category_for(combined_qid) if combined_qid.present?

    topic_cat = topic_qid.present? ? WikidataPropertyLookup.commons_category_for(topic_qid) : nil
    if topic_cat.present? && region_label.present?
      list << "#{topic_cat} in #{region_label}"
    end
    list << topic_cat
    list.compact.map(&:strip).reject(&:blank?).uniq
  end

  # action=query&titles=Category:<name> — pages with `missing` key don't
  # exist. Cached so we don't re-check on every preview/import.
  def self.category_exists?(name)
    return false if name.blank?
    key = "commons:cat_exists:#{name}"
    Rails.cache.fetch(key, expires_in: EXISTENCE_CACHE_TTL) do
      query_category_exists(name)
    end
  end

  def self.query_category_exists(name)
    params = {
      action: "query",
      titles: "Category:#{name}",
      format: "json",
      formatversion: 2
    }
    uri = API.dup
    uri.query = URI.encode_www_form(params)

    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 10) do |h|
      req = Net::HTTP::Get.new(uri)
      req["User-Agent"] = USER_AGENT
      h.request(req)
    end
    return false unless res.is_a?(Net::HTTPSuccess)

    data = JSON.parse(res.body)
    pages = data.dig("query", "pages") || []
    page = pages.first
    !page.nil? && !page["missing"]
  rescue StandardError => e
    Rails.logger.warn "[commons cat exists] #{name}: #{e.class}: #{e.message.slice(0, 200)}"
    false
  end
end
