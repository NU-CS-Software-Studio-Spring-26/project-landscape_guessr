require "rails_helper"

RSpec.describe MatchRound, type: :model do
  # ── Validations ──────────────────────────────────────────────────────────────

  describe "validations" do
    it "is valid with factory defaults" do
      expect(build(:match_round)).to be_valid
    end

    it "rejects a duplicate index within the same match" do
      existing = create(:match_round)
      duplicate = build(:match_round, match: existing.match, index: existing.index,
                                      image: existing.image)
      expect(duplicate).not_to be_valid
      expect(duplicate.errors[:index]).to be_present
    end

    it "allows the same index in different matches" do
      r1 = create(:match_round, index: 1)
      r2 = build(:match_round, index: 1, match: create(:match, :active))
      expect(r2).to be_valid
    end
  end

  # ── Predicate methods ─────────────────────────────────────────────────────────

  describe "#ended?" do
    it "returns false when ended_at is nil" do
      round = build(:match_round)
      expect(round.ended?).to be false
    end

    it "returns true when ended_at is set" do
      round = build(:match_round, :ended)
      expect(round.ended?).to be true
    end
  end

  describe "#expired?" do
    it "returns false when deadline_at is in the future" do
      round = build(:match_round, deadline_at: 1.hour.from_now)
      expect(round.expired?).to be false
    end

    it "returns true when deadline_at is in the past" do
      round = build(:match_round, :expired)
      expect(round.expired?).to be true
    end

    it "returns false when deadline_at is nil" do
      round = build(:match_round, deadline_at: nil)
      # deadline_at is NOT NULL in the schema — covered here for completeness,
      # but the DB would reject nil anyway. The model returns nil (falsy) here.
      expect(round.expired?).to be_falsy
    end
  end
end
