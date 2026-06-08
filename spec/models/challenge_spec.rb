require "rails_helper"

RSpec.describe Challenge, type: :model do
  # ── Token generation ──────────────────────────────────────────────────────────

  describe "token generation" do
    it "sets an 8-character alphanumeric token on create" do
      challenge = create(:challenge)
      expect(challenge.token).to match(/\A[a-z0-9]{8}\z/)
    end

    it "generates a unique token when there is a collision" do
      existing = create(:challenge)
      # Force the first candidate to collide, then generate a fresh one.
      call_count = 0
      allow(SecureRandom).to receive(:alphanumeric).with(8) do
        call_count += 1
        call_count == 1 ? existing.token.downcase : "xxxxxxxx"
      end
      new_challenge = create(:challenge)
      expect(new_challenge.token).not_to eq(existing.token)
    end

    it "uses the token as to_param" do
      challenge = create(:challenge)
      expect(challenge.to_param).to eq(challenge.token)
    end
  end

  # ── #game_for ─────────────────────────────────────────────────────────────────

  describe "#game_for" do
    let(:challenger) { create(:user) }
    let(:player) { create(:user) }
    let(:image_set) { create(:image_set, user: challenger) }
    let(:challenge) { create(:challenge, challenger: challenger) }

    it "returns nil when the player has no games" do
      expect(challenge.game_for(player)).to be_nil
    end

    it "returns the in-progress game when one exists" do
      in_progress = create(:game, user: player, challenge: challenge,
                            image_set: image_set, status: "in_progress")
      create(:game, user: player, challenge: challenge,
             image_set: image_set, status: "completed",
             completed_at: 1.hour.ago)
      expect(challenge.game_for(player)).to eq(in_progress)
    end

    it "returns the most recently created game when all are completed" do
      older = create(:game, user: player, challenge: challenge,
                     image_set: image_set, status: "completed",
                     completed_at: 2.hours.ago, created_at: 2.hours.ago)
      newer = create(:game, user: player, challenge: challenge,
                     image_set: image_set, status: "completed",
                     completed_at: 1.hour.ago, created_at: 1.hour.ago)
      expect(challenge.game_for(player)).to eq(newer)
    end
  end

  # ── #completed_games / #in_progress_games ─────────────────────────────────────

  describe "game filter helpers" do
    let(:challenger) { create(:user) }
    let(:image_set)  { create(:image_set, user: challenger) }
    let(:challenge)  { create(:challenge, challenger: challenger) }
    let(:player)     { create(:user) }

    before do
      create(:game, user: player, challenge: challenge,
             image_set: image_set, status: "completed", completed_at: 1.hour.ago)
      create(:game, user: player, challenge: challenge,
             image_set: image_set, status: "in_progress")
    end

    it "completed_games returns only finished games" do
      expect(challenge.completed_games.size).to eq(1)
      expect(challenge.completed_games.first.completed_at).to be_present
    end

    it "in_progress_games returns only unfinished games" do
      expect(challenge.in_progress_games.size).to eq(1)
      expect(challenge.in_progress_games.first.completed_at).to be_nil
    end
  end
end
