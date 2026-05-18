require "test_helper"

class WikidataImporterTest < ActiveSupport::TestCase
  test "build_random_sparql emits SHA512+RAND ORDER BY shape with nonce + label outside" do
    sparql = WikidataImporter.build_random_sparql(pattern: "?item wdt:P31 wd:Q8072 .", limit: 100)
    # Per-call nonce: WDQS caches by query text. Without this, RAND()
    # materializes on the first call and identical retries return the
    # same "random" sample.
    assert_match(/\A# nonce: [0-9a-f]+\n/, sparql)
    # SHA512(CONCAT(STR(RAND()), STR(?item))) inside an inner subquery
    # — prevents Blazegraph from static-evaluating RAND() to a constant
    # and lets us LIMIT before the outer label join.
    assert_includes sparql, "SHA512(CONCAT(STR(RAND()), STR(?item)))"
    assert_includes sparql, "ORDER BY ?rand"
    assert_includes sparql, "LIMIT 100"
    # Image/article block is INSIDE the random-pick subquery so the cap
    # applies to items that actually have something to display.
    assert_includes sparql, "OPTIONAL { ?item wdt:P18 ?image }"
    assert_includes sparql, "FILTER (BOUND(?image) || BOUND(?article))"
    # Outer SELECT does labels — wikibase:label runs ONCE per surviving
    # LIMIT row instead of for every intermediate join. Per WDQS docs.
    assert_includes sparql, "SELECT ?item ?itemLabel ?image ?coord ?article"
    assert_includes sparql, "SERVICE wikibase:label"
  end

  test "build_random_sparql with_label: false omits the outer label wrapper (for COUNT etc)" do
    sparql = WikidataImporter.build_random_sparql(
      pattern: "?item wdt:P31 wd:Q8072 .", limit: 100, with_label: false
    )
    refute_includes sparql, "SERVICE wikibase:label"
    refute_includes sparql, "?itemLabel"
    # SHA512 randomization is still present
    assert_includes sparql, "SHA512(CONCAT(STR(RAND()), STR(?item)))"
  end

  test "build_random_sparql adds a different nonce per call (cache-bust)" do
    a = WikidataImporter.build_random_sparql(pattern: "?item wdt:P31 wd:Q8072 .", limit: 10)
    b = WikidataImporter.build_random_sparql(pattern: "?item wdt:P31 wd:Q8072 .", limit: 10)
    refute_equal a, b, "two calls with the same args should produce two different nonces"
  end

  test "normalize_rows extracts coords, https-fixed url, label fallback" do
    bindings = [
      {
        "item"      => { "value" => "http://www.wikidata.org/entity/Q1234" },
        "itemLabel" => { "value" => "Mount Foo" },
        "image"     => { "value" => "http://commons.wikimedia.org/wiki/Special:FilePath/foo.jpg" },
        "coord"     => { "value" => "Point(139.6917 35.6895)" }
      },
      {
        "item"      => { "value" => "http://www.wikidata.org/entity/Q5678" },
        "itemLabel" => { "value" => "Q5678" }, # Wikibase fallback — should drop to "Untitled"
        "image"     => { "value" => "https://commons.wikimedia.org/wiki/Special:FilePath/bar.jpg" },
        "coord"     => { "value" => nil },
        "article"   => { "value" => "https://en.wikipedia.org/wiki/Some_Page" }
      }
    ]
    rows = WikidataImporter.normalize_rows(bindings)
    assert_equal "Mount Foo", rows[0][:title]
    assert_equal 35.6895, rows[0][:lat]
    assert_equal 139.6917, rows[0][:lng]
    assert rows[0][:url].start_with?("https:")

    assert_equal "Untitled", rows[1][:title]
    assert_nil rows[1][:lat]
    assert_nil rows[1][:lng]
    assert_equal "https://en.wikipedia.org/wiki/Some_Page", rows[1][:article]
  end

  test "normalize_rows drops rows whose image URL is present but untrusted, keeps nil URLs for pageimages fetch" do
    bindings = [
      { "item"  => { "value" => "http://www.wikidata.org/entity/Q1" },
        "image" => { "value" => nil },                                              # nil URL — kept (pageimages will fill it)
        "article" => { "value" => "https://en.wikipedia.org/wiki/Park_A" } },
      { "item"  => { "value" => "http://www.wikidata.org/entity/Q2" },
        "image" => { "value" => "http://example.com/photo.jpg" } },                 # http, untrusted host — dropped
      { "item"  => { "value" => "http://www.wikidata.org/entity/Q3" },
        "image" => { "value" => "https://malicious.example/payload.jpg" } },        # https but untrusted host — dropped
      { "item"  => { "value" => "http://www.wikidata.org/entity/Q4" },
        "image" => { "value" => "https://commons.wikimedia.org/wiki/Special:FilePath/ok.jpg" } }
    ]
    rows = WikidataImporter.normalize_rows(bindings)
    assert_equal 2, rows.size
    assert_nil rows[0][:url], "nil-URL row should be kept (pageimages mode fills it later)"
    assert_equal "https://en.wikipedia.org/wiki/Park_A", rows[0][:article]
    assert_equal "https://commons.wikimedia.org/wiki/Special:FilePath/ok.jpg", rows[1][:url]
  end

  test "photo_url? rejects non-jpg, non-png, schematics, oversized" do
    good = "https://commons.wikimedia.org/wiki/Special:FilePath/Mount%20Fuji.jpg"
    bad_ext = "https://commons.wikimedia.org/wiki/Special:FilePath/diagram.svg"
    bad_map = "https://commons.wikimedia.org/wiki/Special:FilePath/Location%20map%20Japan.jpg"
    bad_satellite = "https://commons.wikimedia.org/wiki/Special:FilePath/MODIS_satellite_view.jpg"
    long_url = "https://commons.wikimedia.org/wiki/" + ("a" * 500) + ".jpg"

    assert WikidataImporter.photo_url?(good)
    refute WikidataImporter.photo_url?(bad_ext)
    refute WikidataImporter.photo_url?(bad_map)
    refute WikidataImporter.photo_url?(bad_satellite)
    refute WikidataImporter.photo_url?(long_url)
    refute WikidataImporter.photo_url?(nil)
  end

  # === Strategy + pattern-shape helpers ===

  test "extract_single_type pulls Q-ID from P31 (with and without P279*)" do
    assert_equal "Q41176", WikidataImporter.extract_single_type("?item wdt:P31 wd:Q41176 ; wdt:P625 ?coord .")
    assert_equal "Q41176", WikidataImporter.extract_single_type("?item wdt:P31/wdt:P279* wd:Q41176 .")
    assert_nil WikidataImporter.extract_single_type("?item wdt:P2048 ?height . FILTER(?height > 200)")
  end

  test "extract_types returns VALUES qids when present, single type otherwise, [] if neither" do
    values = "VALUES ?type { wd:Q8502 wd:Q23397 } ?item wdt:P31 ?type ."
    assert_equal %w[Q8502 Q23397], WikidataImporter.extract_types(values)
    assert_equal %w[Q41176],       WikidataImporter.extract_types("?item wdt:P31 wd:Q41176 .")
    assert_equal [],               WikidataImporter.extract_types("?item wdt:P2048 ?h . FILTER(?h > 200)")
  end

  test "build_per_type_sparql substitutes QID into VALUES-umbrella pattern + emits SHA512 random shape" do
    pattern = "VALUES ?type { wd:Q8502 } ?item wdt:P31/wdt:P279* ?type . ?item wdt:P625 ?coord ."
    sparql  = WikidataImporter.build_per_type_sparql(
      pattern: pattern, qid: "Q8502", limit: 100, with_label: true
    )
    assert_includes sparql, "wdt:P31/wdt:P279* wd:Q8502"
    refute_includes sparql, "?type"
    refute_includes sparql, "VALUES"
    assert_includes sparql, "SHA512(CONCAT(STR(RAND()), STR(?item)))"
    assert_includes sparql, "SERVICE wikibase:label"
  end

  test "build_per_type_sparql ?type gsub doesn't clobber similar variable names" do
    # plain `gsub("?type", ...)` would corrupt `?typeOfThing`. The
    # word-boundary regex must leave non-?type variables alone.
    pattern = "VALUES ?type { wd:Q1 } ?typeOfThing wdt:P31 ?type . ?item wdt:P625 ?coord ."
    sparql  = WikidataImporter.build_per_type_sparql(
      pattern: pattern, qid: "Q1", limit: 100, with_label: false
    )
    # ?typeOfThing must survive; only the bare ?type gets substituted.
    assert_includes sparql, "?typeOfThing wdt:P31 wd:Q1"
  end

  test "build_per_type_sparql count_only emits plain COUNT(*) without SHA512 randomization" do
    pattern = "?item wdt:P31 wd:Q8502 . ?item wdt:P625 ?coord ."
    sparql  = WikidataImporter.build_per_type_sparql(
      pattern: pattern, qid: "Q8502", limit: 1000, count_only: true, with_label: false
    )
    assert_includes sparql, "SELECT (COUNT(*) AS ?c)"
    # Count = filtered set size; no need to sample-rank for counting.
    refute_includes sparql, "SHA512"
    refute_includes sparql, "ORDER BY ?rand"
  end

  # === run_query retry behavior ===

  test "run_query retries on 502 and succeeds when the retry works" do
    bindings_json = { results: { bindings: [ { "c" => { "value" => "5" } } ] } }.to_json

    # Sequence of HTTP responses: 502, then 200. The retry loop should
    # surface the bindings from the second response without raising.
    queue_http_responses([
      stubbed_response("502", "Bad Gateway"),
      stubbed_response("200", bindings_json)
    ]) do
      assert_no_raise { WikidataImporter.run_query("SELECT ...") }
    end
  end

  test "run_query raises after MAX_RETRIES consecutive 5xx" do
    queue_http_responses([
      stubbed_response("502", "first"),
      stubbed_response("502", "second")
    ]) do
      err = assert_raises(WikidataImporter::Error) { WikidataImporter.run_query("SELECT ...") }
      assert_match(/2 attempts/, err.message)
    end
  end

  test "run_query retries on Net::ReadTimeout" do
    bindings_json = { results: { bindings: [] } }.to_json

    # First call raises timeout, second succeeds.
    call_count = 0
    fake_request = lambda do
      call_count += 1
      raise Net::ReadTimeout, "fake timeout" if call_count == 1
      stubbed_response("200", bindings_json)
    end

    Net::HTTP.stub_any_instance(:request, fake_request) do
      assert_no_raise { WikidataImporter.run_query("SELECT ...") }
    end
    assert_equal 2, call_count
  end

  test "run_query does not retry on 4xx" do
    queue_http_responses([ stubbed_response("400", "bad query") ]) do
      assert_raises(WikidataImporter::Error) { WikidataImporter.run_query("SELECT ...") }
    end
  end

  private

  def stubbed_response(code, body)
    resp = Net::HTTPResponse.send(:response_class, code.to_s).new("1.1", code.to_s, "OK")
    resp.define_singleton_method(:body) { body }
    resp.define_singleton_method(:code) { code.to_s }
    resp
  end

  def queue_http_responses(responses)
    queue = responses.dup
    fake = lambda { queue.shift }
    Net::HTTP.stub_any_instance(:request, fake) { yield }
  end

  def assert_no_raise
    yield
    pass
  rescue StandardError => e
    flunk "Expected no raise, got #{e.class}: #{e.message}"
  end

  # === Region BBOX injection ===

  test "resolve_region_filter exact-matches by name+admin_level+parent" do
    mass = WikidataImporter.resolve_region_filter(
      name: "Massachusetts", parent_name: "United States", admin_level: "admin1"
    )
    assert_equal "Massachusetts", mass&.name
    assert_equal "admin1", mass&.admin_level
    refute_nil mass.min_lat
  end

  test "resolve_region_filter disambiguates Georgia state vs country" do
    state   = WikidataImporter.resolve_region_filter(
      name: "Georgia", parent_name: "United States", admin_level: "admin1"
    )
    country = WikidataImporter.resolve_region_filter(name: "Georgia", admin_level: "country")
    assert_equal "admin1",  state&.admin_level
    assert_equal "country", country&.admin_level
    refute_equal state.id, country.id
  end

  test "resolve_region_filter returns nil for non-canonical names" do
    assert_nil WikidataImporter.resolve_region_filter(
      name: "Bayern", parent_name: "Germany", admin_level: "admin1"
    )
    assert_nil WikidataImporter.resolve_region_filter(
      name: "Massachusetts", parent_name: "USA", admin_level: "admin1"
    )
    assert_nil WikidataImporter.resolve_region_filter(name: nil, admin_level: "admin1")
  end

  test "resolve_region_filter walks parent chain so cities can be matched by their state or country" do
    # In our GeoNames seed, a city's direct parent is always its admin2
    # (county), never the state. But the AI describes cities as "in <state>"
    # or "in <country>" — the resolver has to walk the ancestor chain so
    # both spellings work for the same row.
    expected = regions(:chicago_city)
    by_state   = WikidataImporter.resolve_region_filter(
      name: "Chicago", parent_name: "Illinois", admin_level: "city"
    )
    by_county  = WikidataImporter.resolve_region_filter(
      name: "Chicago", parent_name: "Cook County", admin_level: "city"
    )
    by_country = WikidataImporter.resolve_region_filter(
      name: "Chicago", parent_name: "United States", admin_level: "city"
    )
    assert_equal expected.id, by_state&.id
    assert_equal expected.id, by_county&.id
    assert_equal expected.id, by_country&.id

    # Sibling state must NOT match — disambiguation guard.
    assert_nil WikidataImporter.resolve_region_filter(
      name: "Chicago", parent_name: "Georgia", admin_level: "city"
    )
  end

  test "resolve_region_filter accepts both symbol and string keys" do
    via_symbols = WikidataImporter.resolve_region_filter(
      name: "Massachusetts", parent_name: "United States", admin_level: "admin1"
    )
    via_strings = WikidataImporter.resolve_region_filter(
      "name" => "Massachusetts", "parent_name" => "United States", "admin_level" => "admin1"
    )
    assert_equal via_symbols.id, via_strings.id
  end

  test "with_region_bbox prepends SERVICE wikibase:box (with decoupled coord var) before AI pattern" do
    pattern = "?item wdt:P31 wd:Q23397 ; wdt:P625 ?coord ."
    wrapped = WikidataImporter.with_region_bbox(pattern,
      name: "Massachusetts", parent_name: "United States", admin_level: "admin1")
    assert_includes wrapped, "SERVICE wikibase:box"
    assert_includes wrapped, "cornerSouthWest"
    assert_includes wrapped, "cornerNorthEast"
    assert_match(/Point\(-?\d+\.\d+ -?\d+\.\d+\)/, wrapped)
    # SERVICE must come BEFORE the AI's class triple (or WDQS returns 0
    # matches — empirically verified). And SERVICE binds ?_box_coord, NOT
    # ?coord — if both bind ?coord, WDQS does an exact-WKT match between
    # the two and basically never finds anything.
    service_pos = wrapped.index("SERVICE wikibase:box")
    pattern_pos = wrapped.index(pattern.strip)
    assert service_pos < pattern_pos, "SERVICE wikibase:box must come before the AI's pattern"
    assert_includes wrapped, "?_box_coord"
    refute_match(/SERVICE wikibase:box[^}]+\?item wdt:P625 \?coord/m, wrapped,
                 "SERVICE block must bind a decoupled coord var, not ?coord")
  end

  test "with_region_bbox returns pattern unchanged when region_filter is blank or unresolvable" do
    pattern = "?item wdt:P31 wd:Q23397 ; wdt:P625 ?coord ."
    assert_equal pattern, WikidataImporter.with_region_bbox(pattern, nil)
    assert_equal pattern, WikidataImporter.with_region_bbox(pattern,
      name: "Bayern", parent_name: "Germany", admin_level: "admin1")
  end
end

# Mirror of the helper used in ai_image_set_generator_test.rb. Lets a
# test substitute a fixed value or a lambda for Net::HTTP#request.
class Net::HTTP
  def self.stub_any_instance(method, value)
    aliased = "_pre_stub_#{method}"
    alias_method(aliased, method) unless method_defined?(aliased)
    define_method(method) do |*_args, **_kw|
      value.respond_to?(:call) ? value.call : value
    end
    yield
  ensure
    if method_defined?(aliased)
      alias_method(method, aliased)
      remove_method(aliased)
    end
  end
end
