require "rails_helper"

RSpec.describe MatchPlayer, type: :model do
  # ── Validations ──────────────────────────────────────────────────────────────

  describe "validations" do
    it "is valid with factory defaults" do
      expect(build(:match_player)).to be_valid
    end

    it "rejects a duplicate user in the same match" do
      existing = create(:match_player)
      duplicate = build(:match_player, match: existing.match, user: existing.user)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:user_id]).to be_present
    end

    it "allows the same user in different matches" do
      user = create(:user)
      m1 = create(:match_player, user: user)
      m2 = build(:match_player, user: user, match: create(:match))
      expect(m2).to be_valid
    end
  end

  # ── Callbacks ────────────────────────────────────────────────────────────────

  describe "#ensure_joined_at" do
    it "sets joined_at before validation when blank" do
      mp = build(:match_player, joined_at: nil)
      mp.valid?
      expect(mp.joined_at).to be_present
    end

    it "does not overwrite an already-set joined_at" do
      time = 5.minutes.ago
      mp = build(:match_player, joined_at: time)
      mp.valid?
      expect(mp.joined_at).to be_within(1.second).of(time)
    end
  end

  # ── Scopes ───────────────────────────────────────────────────────────────────

  describe ".active" do
    it "includes players who have not left or forfeited" do
      mp = create(:match_player)
      expect(MatchPlayer.active).to include(mp)
    end

    it "excludes players who have left" do
      mp = create(:match_player, :left)
      expect(MatchPlayer.active).not_to include(mp)
    end

    it "excludes players who have forfeited" do
      mp = create(:match_player, :forfeited)
      expect(MatchPlayer.active).not_to include(mp)
    end
  end
end
