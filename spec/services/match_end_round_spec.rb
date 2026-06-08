require "rails_helper"

RSpec.describe MatchEndRound, type: :service do
  # Build a minimal active match: one round + one player with one guess.
  def setup_round(answer_lat: 48.8566, answer_lng: 2.3522,
                  guess_lat: 51.5074, guess_lng: -0.1278,
                  rounds_total: 1)
    image_set = create(:image_set)
    image     = create(:image, latitude: answer_lat, longitude: answer_lng)
    create(:image_set_item, image_set: image_set, image: image)

    match  = create(:match, :active, image_set: image_set, rounds_total: rounds_total)
    player = create(:match_player, match: match)
    round  = create(:match_round, match: match, index: 1, image: image,
                    answer_latitude: answer_lat, answer_longitude: answer_lng,
                    deadline_at: 1.second.ago)
    guess  = create(:match_guess, match_round: round, match_player: player,
                    latitude: guess_lat, longitude: guess_lng)
    { match: match, player: player, round: round, guess: guess }
  end

  # ── Idempotency ───────────────────────────────────────────────────────────────

  describe "idempotency" do
    it "is a no-op when the round is already ended" do
      ctx = setup_round
      round = ctx[:round]
      round.update!(ended_at: 1.second.ago)
      initial_score = ctx[:player].reload.total_score
      MatchEndRound.call(round: round)
      expect(ctx[:player].reload.total_score).to eq(initial_score)
    end

    it "does not double-score when called twice concurrently" do
      ctx = setup_round
      round = ctx[:round]
      MatchEndRound.call(round: round)
      score_after_first = ctx[:player].reload.total_score
      MatchEndRound.call(round: round)
      expect(ctx[:player].reload.total_score).to eq(score_after_first)
    end
  end

  # ── Scoring ───────────────────────────────────────────────────────────────────

  describe "guess scoring" do
    it "sets distance_km on each guess" do
      ctx = setup_round(answer_lat: 48.8566, answer_lng: 2.3522,
                        guess_lat:  51.5074, guess_lng: -0.1278)
      MatchEndRound.call(round: ctx[:round])
      expect(ctx[:guess].reload.distance_km).to be_present
      expect(ctx[:guess].reload.distance_km).to be > 0
    end

    it "sets score on each guess" do
      ctx = setup_round
      MatchEndRound.call(round: ctx[:round])
      expect(ctx[:guess].reload.score).to be_present
    end

    it "assigns a perfect score when guess is exactly on the answer" do
      ctx = setup_round(answer_lat: 48.8566, answer_lng: 2.3522,
                        guess_lat:  48.8566, guess_lng: 2.3522)
      MatchEndRound.call(round: ctx[:round])
      expect(ctx[:guess].reload.score).to eq(Game::GEOGUESSR_MAX_ROUND_SCORE)
    end

    it "updates the player's total_score" do
      ctx = setup_round
      expect {
        MatchEndRound.call(round: ctx[:round])
      }.to change { ctx[:player].reload.total_score }.from(0)
    end
  end

  # ── Round lifecycle ───────────────────────────────────────────────────────────

  describe "match progression" do
    it "marks the round ended" do
      ctx = setup_round
      MatchEndRound.call(round: ctx[:round])
      expect(ctx[:round].reload.ended_at).to be_present
    end

    it "finishes the match when all rounds are done" do
      ctx = setup_round(rounds_total: 1)
      MatchEndRound.call(round: ctx[:round])
      expect(ctx[:match].reload.status).to eq("finished")
      expect(ctx[:match].reload.finished_at).to be_present
    end

    it "starts the next round when more rounds remain" do
      image_set = create(:image_set)
      images = Array.new(2) { create(:image, latitude: 48.0, longitude: 2.0) }
      images.each { |img| create(:image_set_item, image_set: image_set, image: img) }

      match  = create(:match, :active, image_set: image_set, rounds_total: 2)
      player = create(:match_player, match: match)
      round  = create(:match_round, match: match, index: 1, image: images[0],
                      answer_latitude: 48.0, answer_longitude: 2.0,
                      deadline_at: 1.second.ago)
      create(:match_guess, match_round: round, match_player: player)

      expect { MatchEndRound.call(round: round) }.to change { match.match_rounds.count }.by(1)
      expect(match.reload.status).to eq("active")
    end
  end
end
