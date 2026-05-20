require "test_helper"

class WikidataEntitySearchTest < ActiveSupport::TestCase
  test "returns [] for empty query" do
    assert_equal [], WikidataEntitySearch.search(query: "")
    assert_equal [], WikidataEntitySearch.search(query: "   ")
  end

  test "returns [] when HTTP non-200" do
    stub_response(503, "<html>service unavailable</html>") do
      assert_equal [], WikidataEntitySearch.search(query: "anything")
    end
  end

  test "returns [] when HTTP raises" do
    Net::HTTP.stub_any_instance(:request, -> { raise Net::ReadTimeout }) do
      assert_equal [], WikidataEntitySearch.search(query: "anything")
    end
  end

  test "parses search results into qid/label/description tuples" do
    payload = {
      search: [
        { "id" => "Q5604", "label" => "Frank Lloyd Wright", "description" => "American architect (1867-1959)" },
        { "id" => "Q9999", "label" => "Some other thing",   "description" => nil }
      ]
    }
    stub_response(200, payload.to_json) do
      results = WikidataEntitySearch.search(query: "Frank Lloyd Wright")
      assert_equal 2, results.size
      assert_equal "Q5604", results[0][:qid]
      assert_equal "Frank Lloyd Wright", results[0][:label]
      assert_equal "American architect (1867-1959)", results[0][:description]
      assert_nil results[1][:description]
    end
  end

  private

  def stub_response(status, body)
    fake = Net::HTTPResponse.send(:response_class, status.to_s).new("1.1", status.to_s, "OK")
    fake.define_singleton_method(:body) { body }
    fake.define_singleton_method(:code) { status.to_s }
    Net::HTTP.stub_any_instance(:request, fake) { yield }
  end
end
