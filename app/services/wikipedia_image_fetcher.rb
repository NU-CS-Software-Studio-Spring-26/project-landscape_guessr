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
  USER_AGENT = WikimediaUserAgent::STRING
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
  # on_progress: optional callback called after each batch with
  # (done, total) — both are TITLE counts (50/batch). Used by the
  # importer to advance the "Fetching photos from Wikipedia articles"
  # banner so the user sees the long phase actually making progress
  # instead of sitting on "0 / ?".
  def self.refresh_images!(rows:, on_progress: nil)
    needs_wp = rows.select { |r| r[:article].present? }
    return if needs_wp.empty?

    title_to_row = {}
    needs_wp.each { |r| title_to_row[decode_wp_title(r[:article])] = r }
    titles = title_to_row.keys
    total  = titles.size
    last_batch_idx = ((total - 1) / BATCH_SIZE)

    titles.each_slice(BATCH_SIZE).with_index do |batch, idx|
      pages = fetch_pageimages(batch)
      # Build an api_title → original_title reverse map ONCE per batch.
      # Prior code did `title_to_row.keys.find { ... }` inside the per-
      # page loop — O(batch × titles_total) per import. For a 10k-row
      # import that's ~2.5M comparisons; the reverse map collapses to O(N).
      api_to_original = {}
      batch.each { |t| api_to_original[t] = t }
      (pages[:normalized] || {}).each { |from, to| api_to_original[to] = from if batch.include?(from) }

      pages[:pages].each do |p|
        filename = p["pageimage"]
        next if filename.blank?
        original = api_to_original[p["title"]]
        next unless original
        row = title_to_row[original]
        next unless row
        row[:url] = FILEPATH + URI.encode_www_form_component(filename).gsub("+", "%20")
      end

      done = [ (idx + 1) * BATCH_SIZE, total ].min
      on_progress&.call(done, total)

      # Courtesy delay between batches — Wikipedia's API has soft per-IP
      # limits and we want to stay polite at the 10k-row scale.
      sleep 0.2 unless idx == last_batch_idx
    end
    rows
  end

  def self.fetch_pageimages(titles)
    t0 = Time.now
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
    duration = Time.now - t0

    # `titles_list` logs the full pipe-joined batch so a failing call
    # can be reproduced verbatim by pasting it into the MediaWiki API
    # sandbox. Batches are bounded at BATCH_SIZE (50) — ~3 KB worst
    # case, fine for log volume.
    titles_list = titles.join("|")
    unless response.code == "200"
      WikidataQueryLog.log(action: :pageimages, status: response.code, duration: duration,
                            batch: titles.size, titles: titles_list,
                            error: response.body.to_s.slice(0, 200))
      return { pages: [], normalized: {} }
    end

    data = JSON.parse(response.body)
    pages = (data.dig("query", "pages") || {}).values
    with_image = pages.count { |p| p["pageimage"].present? }
    WikidataQueryLog.log(action: :pageimages, status: response.code, duration: duration,
                          batch: titles.size, with_image: with_image, titles: titles_list)
    {
      pages: pages,
      normalized: (data.dig("query", "normalized") || []).each_with_object({}) { |n, h| h[n["from"]] = n["to"] }
    }
  rescue StandardError => e
    WikidataQueryLog.log(action: :pageimages, status: "exception", duration: Time.now - t0,
                          batch: titles.size, error: "#{e.class}: #{e.message.slice(0, 200)}")
    { pages: [], normalized: {} }
  end

  # https://en.wikipedia.org/wiki/Mount_Fuji → "Mount Fuji"
  def self.decode_wp_title(article_url)
    encoded = article_url.split("/wiki/").last.to_s
    URI.decode_www_form_component(encoded).tr("_", " ")
  end
end
