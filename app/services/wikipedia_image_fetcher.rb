require "net/http"
require "uri"
require "json"

# Looks up the lead image (PageImages-extension scored winner — usually
# the infobox photo) for a list of en.wikipedia articles, and rewrites
# each row's :url to a Special:FilePath link.
#
# Why "infobox photo" instead of Wikidata's P18: P18 statements are
# often years out of date; Wikipedia infoboxes get refreshed when an
# article is updated. For categories where freshness matters (buildings
# undergoing renovation, transit infrastructure, anything modern), the
# user / AI can opt into image_source: "wikipedia_pageimages" and we
# overwrite P18 with the article's current lead image.
class WikipediaImageFetcher
  API = URI("https://en.wikipedia.org/w/api.php").freeze
  # MediaWiki cap per request — verified at https://www.mediawiki.org/wiki/API:Query.
  BATCH_SIZE = 50
  USER_AGENT = "landscape-guessr/ai-image-sets (https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr) Ruby/#{RUBY_VERSION}".freeze
  FILEPATH = "https://commons.wikimedia.org/wiki/Special:FilePath/".freeze
  READ_TIMEOUT = 60

  # WHY-NO-REDIRECTS: we do NOT pass redirects=1. If we did, MediaWiki
  # would silently follow page → place/list-article redirects (e.g.
  # Wikidata sometimes sitelinks a station's article to a town article),
  # and we'd import the redirect-target's lead image as if it were the
  # station's image. The cost: ~15-20 rows per ~5000 silently get no
  # image (and are dropped at the URL-blank filter). That tradeoff is
  # the right default — if you need redirect-following, add it as an
  # opt-in flag, but do not make it default.
  def self.refresh_images!(rows:)
    needs_wp = rows.select { |r| r[:article].present? }
    return if needs_wp.empty?

    title_to_row = {}
    needs_wp.each { |r| title_to_row[decode_wp_title(r[:article])] = r }
    titles = title_to_row.keys

    titles.each_slice(BATCH_SIZE).with_index do |batch, idx|
      pages = fetch_pageimages(batch)
      normalized = pages[:normalized] || {}
      pages[:pages].each do |p|
        filename = p["pageimage"]
        next if filename.blank?

        api_title = p["title"]
        original = title_to_row.keys.find { |t| t == api_title || normalized[t] == api_title }
        next unless original

        row = title_to_row[original]
        row[:url] = FILEPATH + URI.encode_www_form_component(filename).gsub("+", "%20")
      end

      # Courtesy delay between batches — Wikipedia's API has soft per-IP
      # limits and we want to stay polite at the 10k-row scale.
      sleep 0.2 unless idx == (titles.size / BATCH_SIZE.to_f).ceil - 1
    end
    rows
  end

  def self.fetch_pageimages(titles)
    params = {
      action: "query",
      format: "json",
      prop:   "pageimages",
      piprop: "name",
      titles: titles.join("|")
    }

    req = Net::HTTP::Post.new(API)
    req["User-Agent"]   = USER_AGENT
    req["Accept"]       = "application/json"
    req["Content-Type"] = "application/x-www-form-urlencoded"
    req.body = URI.encode_www_form(params)

    response = Net::HTTP.start(API.hostname, API.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
      h.request(req)
    end

    return { pages: [], normalized: {} } unless response.code == "200"

    data = JSON.parse(response.body)
    {
      pages: (data.dig("query", "pages") || {}).values,
      normalized: (data.dig("query", "normalized") || []).each_with_object({}) { |n, h| h[n["from"]] = n["to"] }
    }
  rescue StandardError
    { pages: [], normalized: {} }
  end

  # https://en.wikipedia.org/wiki/Mount_Fuji → "Mount Fuji"
  def self.decode_wp_title(article_url)
    encoded = article_url.split("/wiki/").last.to_s
    URI.decode_www_form_component(encoded).tr("_", " ")
  end
end
