require "test_helper"

class ImageTest < ActiveSupport::TestCase
  test "has many guesses" do
    assert_equal :has_many, Image.reflect_on_association(:guesses).macro
  end

  test "destroying image destroys its guesses" do
    image = images(:one)
    guess_count = image.guesses.count
    assert guess_count > 0
    assert_difference("Guess.count", -guess_count) { image.destroy }
  end

  test "fixture is valid" do
    image = images(:one)
    assert image.url.present?
    assert image.latitude.present?
    assert image.longitude.present?
    assert image.title.present?
  end

  test "bulk_insert_for_source! reuses an existing image with the same url instead of violating the url index" do
    set = image_sets(:alice_private)
    shared_url = "https://commons.wikimedia.org/wiki/Special:FilePath/Shared_Collision_Test.jpg"
    existing = Image.create!(external_source: "wikidata", external_id: "Q-collision-#{rand(10_000)}",
                             url: shared_url, title: "Existing", latitude: 1.0, longitude: 2.0)

    # A Commons row for the SAME file (same url, different source identity).
    rows = [ { external_source: "commons", external_id: "commons-pid-#{rand(10_000)}",
               url: shared_url, title: "Same File", lat: 1.0, lng: 2.0 } ]

    assert_nothing_raised do
      Image.bulk_insert_for_source!(image_set: set, rows: rows, source: "commons")
    end
    # No duplicate image was created; the existing one was linked to the set.
    assert_equal 1, Image.where(url: shared_url).count
    assert set.reload.images.exists?(id: existing.id)
  end

  test "bulk_insert_for_source! does not collapse rows with blank urls (Mapillary)" do
    set = image_sets(:alice_private)
    rows = [
      { external_source: "mapillary", external_id: "mly-a-#{rand(10_000)}", url: nil, lat: 1.0, lng: 2.0 },
      { external_source: "mapillary", external_id: "mly-b-#{rand(10_000)}", url: nil, lat: 3.0, lng: 4.0 }
    ]
    assert_difference("Image.count", 2) do
      Image.bulk_insert_for_source!(image_set: set, rows: rows, source: "mapillary")
    end
  end
end
