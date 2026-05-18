require "net/http"
require "uri"
require "json"

# Companion to WikidataEntitySearch. Where search resolves a label to
# a Q-ID, this service resolves a Q-ID to a peek at its claims —
# letting the AI verify how Wikidata actually models a thing before
# composing a SPARQL query.
#
# Use case: AI knows the user wants "UNESCO sites in Europe" and finds
# Q9259 via search. But is "UNESCO World Heritage Site" modeled as
# `?item wdt:P31 wd:Q9259` (instance) or `?item wdt:P1435 wd:Q9259`
# (designation)? AI can inspect a known example like Q131013 (Acropolis)
# and see the P1435 claim, removing the guess.
#
# Backed by wbgetentities (https://www.wikidata.org/w/api.php?action=
# wbgetentities). Returns the top properties with their values + labels.
# Excludes language-tagged labels/descriptions/sitelinks/aliases — the
# AI only needs the claim structure.
class WikidataEntityInspect
  API = URI("https://www.wikidata.org/w/api.php").freeze
  USER_AGENT = WikimediaUserAgent::STRING
  READ_TIMEOUT = 15

  # Cap how many distinct properties we return. ~25 covers the most
  # claimed properties for most entities; more would bloat the response
  # the AI has to parse without proportional value.
  MAX_PROPERTIES = 25

  # Returns a compact summary of the entity's claims, in a shape the AI
  # can quickly skim. Returns nil on lookup failure / missing entity.
  def self.inspect_entity(qid:)
    qid = qid.to_s.strip.upcase
    return nil unless qid.match?(/\AQ\d+\z/)

    params = {
      action:    "wbgetentities",
      ids:       qid,
      props:     "labels|descriptions|claims",
      languages: "en",
      format:    "json"
    }
    uri = API.dup
    uri.query = URI.encode_www_form(params)

    req = Net::HTTP::Get.new(uri)
    req["User-Agent"] = USER_AGENT
    req["Accept"]     = "application/json"

    t0 = Time.now
    response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
      h.request(req)
    end
    duration = Time.now - t0

    unless response.code == "200"
      WikidataQueryLog.log(action: :wbgetent, status: response.code, duration: duration, qid: qid)
      return nil
    end

    json = JSON.parse(response.body)
    entity = json.dig("entities", qid)
    unless entity
      WikidataQueryLog.log(action: :wbgetent, status: response.code, duration: duration,
                            qid: qid, found: false)
      return nil
    end

    claims = summarize_claims(entity["claims"] || {})
    WikidataQueryLog.log(action: :wbgetent, status: response.code, duration: duration,
                          qid: qid, properties: claims.size)
    {
      qid:         qid,
      label:       entity.dig("labels", "en", "value"),
      description: entity.dig("descriptions", "en", "value"),
      claims:      claims
    }
  rescue StandardError => e
    WikidataQueryLog.log(action: :wbgetent, status: "exception", duration: Time.now - t0,
                          qid: qid, error: "#{e.class}: #{e.message.slice(0, 200)}")
    nil
  end

  # Wikidata claims structure: { "P31" => [{mainsnak: {datavalue: {value: ...}}}], ...}
  # We boil down to: [{property: "P31", values: ["Q41176", "Q23413"]}, ...]
  # Items: just the Q-ID. Strings/dates/etc: short string. Other types skipped
  # for brevity (an inspect of a famous building can return tens of
  # statement-on-statement nested values otherwise).
  def self.summarize_claims(claims)
    claims.first(MAX_PROPERTIES).map do |pid, statements|
      values = statements.first(8).filter_map { |s| claim_value(s) }
      { property: pid, values: values.uniq.first(8) }
    end
  end

  def self.claim_value(statement)
    snak = statement.dig("mainsnak")
    return nil unless snak && snak["snaktype"] == "value"
    dv = snak["datavalue"] || {}
    case dv["type"]
    when "wikibase-entityid"
      id = dv.dig("value", "id")
      id if id&.match?(/\A[QP]\d+\z/)
    when "string", "external-id"
      dv["value"].to_s.slice(0, 60)
    when "monolingualtext"
      dv.dig("value", "text").to_s.slice(0, 60)
    when "time"
      dv.dig("value", "time").to_s.slice(0, 30)
    when "quantity"
      dv.dig("value", "amount").to_s
    when "globecoordinate"
      lat = dv.dig("value", "latitude")
      lng = dv.dig("value", "longitude")
      "Point(#{lng} #{lat})" if lat && lng
    end
  end
end
