require "net/http"
require "uri"
require "json"

# Wraps Wikidata's `wbsearchentities` API so the AI can resolve labels
# like "Frank Lloyd Wright" or "volcano" to a Q-ID at query time. Read-
# only, no auth required, no cost. We expose this as a Gemini
# function-call tool — see AiImageSetGenerator's tools[] declaration.
#
# The AI tells us a free-form label; we return the top N matches as
# (qid, label, description) tuples. The AI picks one. This is more
# accurate than relying on the AI's memory of Q-IDs, which is famously
# unreliable for niche entities.
#
# Etiquette: Wikidata asks bots to send a User-Agent identifying the
# project + contact. Per their robot policy unauthenticated traffic gets
# rate-limited harder than identified traffic.
class WikidataEntitySearch
  API = URI("https://www.wikidata.org/w/api.php").freeze
  USER_AGENT = "landscape-guessr/ai-image-sets (https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr) Ruby/#{RUBY_VERSION}".freeze
  READ_TIMEOUT = 15

  # Returns up to `limit` matches. `type` filters by entity kind:
  # "item" (default) for things, "property" for P-IDs.
  #
  # Returns an array of { qid:, label:, description:, matched_via: }
  # hashes. `matched_via` is "label" if the user's query matched the
  # canonical English label, "alias <alias-text>" if it matched a
  # variant name (e.g. "FLW" matching "Frank Lloyd Wright"). That's
  # useful disambiguation signal — a Q-ID whose label disagrees with
  # the user's query but matched via alias might still be the right
  # entity, vs. an alphabetical-match coincidence.
  #
  # limit default 10 (up from 5): for common-noun searches like
  # "country" or "mountain" the conceptual entity is often NOT in the
  # top 5 (label-match ranking). 10 covers the typical concept's actual
  # rank without significantly bloating the AI's context.
  #
  # Empty array on no match OR transient API failure — raising would
  # abort the whole AI turn; better to let the AI either retry with a
  # different query or call submit_answer(cannot_answer=true).
  def self.search(query:, type: "item", limit: 10)
    return [] if query.to_s.strip.empty?

    params = {
      action:   "wbsearchentities",
      search:   query.to_s.strip.first(200),
      language: "en",
      uselang:  "en",
      format:   "json",
      type:     type,
      limit:    [ limit.to_i.clamp(1, 20), 20 ].min
    }
    uri = API.dup
    uri.query = URI.encode_www_form(params)

    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept"]     = "application/json"

    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
      h.request(req)
    end

    return [] unless response.code == "200"

    json = JSON.parse(response.body)
    (json["search"] || []).map do |hit|
      match = hit["match"] || {}
      matched_via =
        if match["type"] == "alias" && match["text"].present?
          "alias #{match['text']}"
        else
          (match["type"] || "label").to_s
        end
      {
        qid:         hit["id"],
        label:       hit["label"],
        description: hit["description"],
        matched_via: matched_via
      }
    end
  rescue StandardError => e
    Rails.logger.warn "[WikidataEntitySearch] #{e.class}: #{e.message}" if defined?(Rails)
    []
  end
end
