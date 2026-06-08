require "rails_helper"

RSpec.describe MatchStartRound, type: :service do
  # Shared helpers ──────────────────────────────────────────────────────────────

  # Build a match with `n` usable image_set_items attached.
  def match_with_images(n, seconds_per_round: 30)
    image_set = create(:image_set)
    match = create(:match, :active, image_set: image_set,
                   rounds_total: n, seconds_per_round: seconds_per_round)
    n.times do
      image = create(:image, latitude: 48.8566, longitude: 2.3522)
      create(:image_set_item, image_set: image_set, image: image)
    end
    match
  end

  # ── Happy path ───────────────────────────────────────────────────────────────

  describe "successful round creation" do
    it "creates a MatchRound with index 1 for the first round" do
      match = match_with_images(3)
      round = MatchStartRound.call(match: match)
      expect(round).to be_a(MatchRound)
      expect(round.index).to eq(1)
    end

    it "increments the index for subsequent rounds" do
      match = match_with_images(3)
      _r1 = MatchStartRound.call(match: match)
      r2  = MatchStartRound.call(match: match)
      expect(r2.index).to eq(2)
    end

    it "sets started_at to approximately now" do
      match = match_with_images(1)
      round = MatchStartRound.call(match: match)
      expect(round.started_at).to be_within(2.seconds).of(Time.current)
    end

    it "sets deadline_at = started_at + seconds_per_round" do
      match = match_with_images(1, seconds_per_round: 45)
      round = MatchStartRound.call(match: match)
      expected_deadline = round.started_at + 45.seconds
      expect(round.deadline_at).to be_within(1.second).of(expected_deadline)
    end

    it "persists the answer coords from the image_set_item" do
      image_set = create(:image_set)
      image = create(:image, latitude: 51.5074, longitude: -0.1278)
      create(:image_set_item, image_set: image_set, image: image)
      match = create(:match, :active, image_set: image_set, rounds_total: 1)
      round = MatchStartRound.call(match: match)
      expect(round.answer_latitude.to_f).to be_within(0.0001).of(51.5074)
      expect(round.answer_longitude.to_f).to be_within(0.0001).of(-0.1278)
    end

    it "enqueues EndMatchRoundJob to fire after seconds_per_round" do
      match = match_with_images(1, seconds_per_round: 30)
      expect {
        MatchStartRound.call(match: match)
      }.to have_enqueued_job(EndMatchRoundJob).on_queue("default")
    end
  end

  # ── Nil-return cases ─────────────────────────────────────────────────────────

  describe "returns nil" do
    it "returns nil when rounds_total is already reached" do
      match = match_with_images(2)
      MatchStartRound.call(match: match) # round 1
      MatchStartRound.call(match: match) # round 2 (exhausts rounds_total=2)
      result = MatchStartRound.call(match: match)
      expect(result).to be_nil
    end

    it "returns nil when the image set has no more unused usable images" do
      image_set = create(:image_set)
      image = create(:image, latitude: 48.8566, longitude: 2.3522)
      create(:image_set_item, image_set: image_set, image: image)
      match = create(:match, :active, image_set: image_set, rounds_total: 5)
      # Use the only available image in round 1
      MatchStartRound.call(match: match)
      # Round 2 has no unused images left
      result = MatchStartRound.call(match: match)
      expect(result).to be_nil
    end

    it "returns nil when the image set has no images at all" do
      match = create(:match, :active, image_set: create(:image_set), rounds_total: 3)
      expect(MatchStartRound.call(match: match)).to be_nil
    end
  end

  # ── No image reuse ───────────────────────────────────────────────────────────

  describe "image reuse prevention" do
    it "never picks the same image twice across rounds" do
      image_set = create(:image_set)
      images = Array.new(3) { create(:image, latitude: 48.0, longitude: 2.0) }
      images.each { |img| create(:image_set_item, image_set: image_set, image: img) }
      match = create(:match, :active, image_set: image_set, rounds_total: 3)

      round_ids = []
      3.times { round = MatchStartRound.call(match: match); round_ids << round.image_id }
      expect(round_ids.uniq.size).to eq(3)
    end
  end
end
