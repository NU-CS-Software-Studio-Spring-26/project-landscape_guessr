require "net/http"
require "uri"

# Tells us whether an image URL actually serves bytes. Used by
# GamesController#create and ChallengesController#create to pre-validate
# the 5 picked image URLs before locking them in — so the player never
# sees a broken thumbnail at round time. Parallel HEAD per URL, ~300ms
# wall time for a clean batch of 5.
#
# Why HEAD-with-follow_redirects works for Commons specifically:
#   https://commons.wikimedia.org/wiki/Special:FilePath/Foo.jpg
#     → 302 https://commons.wikimedia.org/wiki/Special:Redirect/file/Foo.jpg
#     → if exists: 301 https://upload.wikimedia.org/...    → 200
#     → if missing: 404
# A naive HEAD without follow gets the 302 and tells us nothing.
class ImageReachability
  TIMEOUT       = 3
  MAX_REDIRECTS = 5

  Result = Struct.new(:status, :http_code) do
    def ok?      = status == :ok
    def broken?  = status == :broken
    def unknown? = status == :unknown
  end

  # Parallel reachability check. Returns the subset of `urls` that
  # resolve OK (:ok). Treats :unknown as ok — we can't prove it's broken,
  # better to keep the URL than drop a row on a transient blip.
  # Used by GamesController and ChallengesController to filter picked
  # items at create time so the player never sees a broken thumbnail.
  def self.reachable(urls)
    return [] if urls.blank?
    results = Array.new(urls.size)
    threads = urls.each_with_index.map do |url, i|
      Thread.new { results[i] = check(url) }
    end
    threads.each(&:join)
    urls.each_with_index.filter_map { |url, i| url if results[i].ok? || results[i].unknown? }
  end

  # :ok      — final response was 2xx
  # :broken  — final response was 404 or 410
  # :unknown — timeout, DNS failure, 5xx, or anything else inconclusive
  def self.check(url)
    return Result.new(:unknown, nil) if url.blank?
    uri       = URI.parse(url)
    redirects = 0
    loop do
      return Result.new(:unknown, nil) unless %w[http https].include?(uri.scheme)
      req = Net::HTTP::Head.new(uri.request_uri)
      req["User-Agent"] = WikimediaUserAgent::STRING
      response = Net::HTTP.start(
        uri.hostname, uri.port,
        use_ssl:      uri.scheme == "https",
        open_timeout: TIMEOUT,
        read_timeout: TIMEOUT
      ) { |h| h.request(req) }

      case response
      when Net::HTTPSuccess
        return Result.new(:ok, response.code.to_i)
      when Net::HTTPRedirection
        redirects += 1
        return Result.new(:unknown, response.code.to_i) if redirects > MAX_REDIRECTS
        location = response["location"]
        return Result.new(:unknown, response.code.to_i) if location.blank?
        uri = URI.join(uri, location)
      when Net::HTTPNotFound, Net::HTTPGone
        return Result.new(:broken, response.code.to_i)
      else
        return Result.new(:unknown, response.code.to_i)
      end
    end
  rescue StandardError
    Result.new(:unknown, nil)
  end
end
