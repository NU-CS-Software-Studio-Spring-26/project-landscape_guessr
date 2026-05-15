require "test_helper"

class WikidataImporterTest < ActiveSupport::TestCase
  test "wrap_with_limit appends OPTIONAL+FILTER trailer + label service" do
    sparql = WikidataImporter.wrap_with_limit("?item wdt:P31 wd:Q8072 .", limit: 100)
    assert_includes sparql, "SELECT DISTINCT ?item ?itemLabel"
    assert_includes sparql, "OPTIONAL { ?item wdt:P18 ?image }"
    assert_includes sparql, "FILTER (BOUND(?image) || BOUND(?article))"
    assert_includes sparql, "SERVICE wikibase:label"
    assert_includes sparql, "LIMIT 100"
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
        "image"     => { "value" => nil },
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
end
