require "net/http"
require "uri"
require "json"

# Mapillary signed thumb URLs expire (~30 days) so we store NULL in
# `images.url` and resolve lazily at render time. Single + batch entry
# points; results cached in Rails.cache for 6 hours.
#
# Graph API:
#   GET https://graph.mapillary.com/<image_id>?fields=thumb_2048_url
#   Authorization: OAuth <token>
#
# Batch endpoint is `?ids=A,B,C&fields=thumb_2048_url`. We send BATCH_SIZE
# (50) IDs per request — comfortably within what the Graph API accepts.
class MapillaryUrlResolver
  API = URI("https://graph.mapillary.com").freeze
  CACHE_TTL = 6.hours
  BATCH_SIZE = 50
  READ_TIMEOUT = 15
  DEFAULT_SIZE = 2048

  # Returns a signed URL or nil (404, network failure).
  def self.url_for(image_id, size: DEFAULT_SIZE)
    return nil if image_id.blank?
    Rails.cache.fetch(cache_key(image_id, size), expires_in: CACHE_TTL) do
      fetch_one(image_id, size)
    end
  end

  # Resolves many image IDs at once and returns the FULL {image_id => url}
  # map for every requested id — cache hits included. Callers (the preview
  # sampler, the gallery) read URLs straight off the return value, so
  # returning only freshly-fetched ids meant a second call for the same
  # images (all now cached) came back empty and rendered blank thumbnails
  # with dead `href=""` links. Read-through is the correct contract.
  def self.warm_urls(image_ids, size: DEFAULT_SIZE)
    ids = Array(image_ids).map(&:to_s).reject(&:blank?).uniq
    return {} if ids.empty?

    result = {}
    to_fetch = []
    ids.each do |id|
      cached = Rails.cache.read(cache_key(id, size))
      if cached.nil? && !Rails.cache.exist?(cache_key(id, size))
        to_fetch << id
      else
        result[id] = cached
      end
    end

    to_fetch.each_slice(BATCH_SIZE) do |batch|
      batch_result = fetch_batch(batch, size)
      batch.each do |id|
        url = batch_result[id]
        Rails.cache.write(cache_key(id, size), url, expires_in: CACHE_TTL)
        result[id] = url
      end
    end
    result.compact
  end

  def self.cache_key(image_id, size)
    "mly:url:#{size}:#{image_id}"
  end

  def self.token
    ENV["MAPILLARY_TOKEN"].presence || (raise "MAPILLARY_TOKEN not set")
  end

  # Single fetch — returns the URL string or nil.
  def self.fetch_one(image_id, size)
    field = "thumb_#{size}_url"
    uri = API.dup
    uri.path = "/#{image_id}"
    uri.query = URI.encode_www_form(fields: field)
    res = http_get(uri)
    return nil unless res
    json = JSON.parse(res)
    json[field].presence
  rescue StandardError => e
    Rails.logger.warn "[mly url] #{image_id}: #{e.class}: #{e.message.slice(0, 200)}"
    nil
  end

  # Batch fetch — returns {image_id => url_or_nil}.
  #
  # Mapillary's batch response shape is `{ "<id>": { "<field>": "<url>" }, ... }`
  # — an object keyed by image_id, NOT a `{data: [...]}` wrapper like FB Graph's
  # generic batch. Verified by direct curl.
  def self.fetch_batch(image_ids, size)
    field = "thumb_#{size}_url"
    uri = URI("https://graph.mapillary.com/")
    uri.query = URI.encode_www_form(ids: image_ids.join(","), fields: field)
    res = http_get(uri)
    return {} unless res
    json = JSON.parse(res)
    out = {}
    json.each do |id, entry|
      next unless entry.is_a?(Hash)
      out[id.to_s] = entry[field].presence
    end
    out
  rescue StandardError => e
    Rails.logger.warn "[mly url batch] #{image_ids.size} ids: #{e.class}: #{e.message.slice(0, 200)}"
    {}
  end

  def self.http_get(uri)
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: READ_TIMEOUT) do |h|
      req = Net::HTTP::Get.new(uri)
      req["Authorization"] = "OAuth #{token}"
      h.request(req)
    end
    return nil unless res.is_a?(Net::HTTPSuccess)
    res.body
  end
end
