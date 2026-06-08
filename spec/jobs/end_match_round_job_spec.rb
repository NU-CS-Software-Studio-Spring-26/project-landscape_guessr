require "rails_helper"

RSpec.describe EndMatchRoundJob, type: :job do
  include ActiveJob::TestHelper

  describe "#perform" do
    it "calls MatchEndRound with the correct round" do
      match  = create(:match, :active)
      image  = create(:image, latitude: 48.8566, longitude: 2.3522)
      create(:image_set_item, image_set: match.image_set, image: image)
      round  = create(:match_round, match: match, index: 1, image: image,
                      answer_latitude: 48.8566, answer_longitude: 2.3522,
                      deadline_at: 1.second.ago)

      expect(MatchEndRound).to receive(:call).with(round: round)
      described_class.perform_now(round.id)
    end

    it "does nothing gracefully when the round no longer exists" do
      expect { described_class.perform_now(999_999) }.not_to raise_error
    end

    it "is enqueued on the default queue" do
      expect(described_class.new.queue_name).to eq("default")
    end
  end
end
