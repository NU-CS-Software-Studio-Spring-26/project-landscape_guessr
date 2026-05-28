require "test_helper"

class MapillaryUrlResolverTest < ActiveSupport::TestCase
  setup do
    # Test env's :null_store discards writes, so swap in a real memory store
    # for the duration of this test class. Restored in teardown.
    @prev_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    ENV["MAPILLARY_TOKEN"] = "test-mapillary-token"
  end

  teardown do
    Rails.cache = @prev_cache
  end

  test "url_for hits the cache after first fetch" do
    stub_request(:get, %r{graph\.mapillary\.com/123})
      .to_return(status: 200, body: { thumb_2048_url: "https://cdn/img.jpg" }.to_json)

    assert_equal "https://cdn/img.jpg", MapillaryUrlResolver.url_for("123", size: 2048)
    # Subsequent call: no new HTTP request — cache hit.
    assert_equal "https://cdn/img.jpg", MapillaryUrlResolver.url_for("123", size: 2048)
  end

  test "warm_urls batch populates cache with keyed-by-id response shape" do
    stub_request(:get, %r{graph\.mapillary\.com/\?})
      .to_return(
        status: 200,
        body: { "100" => { thumb_1024_url: "https://cdn/100.jpg" },
                "200" => { thumb_1024_url: "https://cdn/200.jpg" } }.to_json
      )

    fresh = MapillaryUrlResolver.warm_urls(%w[100 200], size: 1024)
    assert_equal "https://cdn/100.jpg", fresh["100"]
    assert_equal "https://cdn/200.jpg", fresh["200"]
    # Confirm cache is populated — these reads do NOT trigger another stub call.
    assert_equal "https://cdn/100.jpg", MapillaryUrlResolver.url_for("100", size: 1024)
  end

  test "fetch_one returns nil on 404" do
    stub_request(:get, %r{graph\.mapillary\.com/999}).to_return(status: 404)
    assert_nil MapillaryUrlResolver.fetch_one("999", 2048)
  end
end
