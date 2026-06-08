require "rails_helper"

RSpec.describe MatchGuess, type: :model do
  # ── Validations ──────────────────────────────────────────────────────────────

  describe "validations" do
    it "is valid with factory defaults" do
      expect(build(:match_guess)).to be_valid
    end

    it "rejects a second guess from the same player in the same round" do
      existing = create(:match_guess)
      duplicate = build(:match_guess,
                        match_round: existing.match_round,
                        match_player: existing.match_player)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:match_player_id]).to be_present
    end

    it "allows the same player to guess in different rounds" do
      player = create(:match_player)
      match  = player.match
      image  = create(:image)
      r1 = create(:match_round, match: match, index: 1, image: image)
      r2 = create(:match_round, match: match, index: 2, image: image)
      g1 = create(:match_guess, match_round: r1, match_player: player)
      g2 = build(:match_guess, match_round: r2, match_player: player)
      expect(g2).to be_valid
    end
  end

  # ── Callbacks ────────────────────────────────────────────────────────────────

  describe "#ensure_submitted_at" do
    it "sets submitted_at before validation when blank" do
      guess = build(:match_guess, submitted_at: nil)
      guess.valid?
      expect(guess.submitted_at).to be_present
    end
  end
end
