require "rails_helper"

RSpec.describe "Matches", type: :request do
  include ActiveJob::TestHelper

  let(:host)      { create(:user) }
  let(:other)     { create(:user) }
  let(:image_set) { create(:image_set, user: host) }

  # Build a match with at least one usable image in its set.
  def match_with_image(status: "lobby", **attrs)
    image = create(:image, latitude: 48.8566, longitude: 2.3522)
    create(:image_set_item, image_set: image_set, image: image)
    create(:match, status: status, host: host, image_set: image_set, **attrs)
  end

  # ── Authentication guard ─────────────────────────────────────────────────────

  describe "GET /matches/new" do
    it "redirects guests to the login page" do
      get new_match_path
      expect(response).to redirect_to(new_session_path)
    end

    it "returns 200 for signed-in users" do
      sign_in_as host
      get new_match_path
      expect(response).to have_http_status(:ok)
    end
  end

  # ── POST /matches (create) ────────────────────────────────────────────────────

  describe "POST /matches" do
    before { sign_in_as host }

    it "creates a match and its host MatchPlayer row, then redirects to the lobby" do
      expect {
        post matches_path, params: { image_set_id: image_set.id, rounds_total: 3,
                                     seconds_per_round: 45 }
      }.to change(Match, :count).by(1).and change(MatchPlayer, :count).by(1)
      expect(response).to redirect_to(match_path(Match.last.code))
    end

    it "clamps rounds_total to 20 when the value is too large" do
      post matches_path, params: { image_set_id: image_set.id, rounds_total: 999 }
      expect(Match.last.rounds_total).to eq(20)
    end

    it "uses a default of 5 rounds when rounds_total is blank" do
      post matches_path, params: { image_set_id: image_set.id }
      expect(Match.last.rounds_total).to eq(5)
    end

    it "re-renders the form with 422 when an invalid image_set_id is given" do
      post matches_path, params: { image_set_id: 999_999, rounds_total: 3 }
      expect(response).to have_http_status(:found) # redirects with alert
    end
  end

  # ── GET /matches/:code (show / lobby) ─────────────────────────────────────────

  describe "GET /matches/:code" do
    it "returns 200 for the host in lobby" do
      match = match_with_image
      sign_in_as host
      get match_path(match.code)
      expect(response).to have_http_status(:ok)
    end

    it "returns 200 for an anonymous visitor who knows the code (lobby view)" do
      match = match_with_image
      sign_in_as other
      get match_path(match.code)
      expect(response).to have_http_status(:ok)
    end

    it "redirects with not_found for an unknown code" do
      sign_in_as host
      get match_path("XXXXXX")
      expect(response).to redirect_to(root_path)
    end
  end

  # ── POST /matches/:code/join ──────────────────────────────────────────────────

  describe "POST /matches/:code/join" do
    it "creates a MatchPlayer and redirects to the lobby" do
      match = match_with_image
      sign_in_as other
      expect {
        post join_match_path(match.code)
      }.to change(MatchPlayer, :count).by(1)
      expect(response).to redirect_to(match_path(match.code))
    end

    it "is idempotent — joining again does not create a second row" do
      match = match_with_image
      sign_in_as other
      post join_match_path(match.code)
      expect {
        post join_match_path(match.code)
      }.not_to change(MatchPlayer, :count)
    end

    it "redirects with an alert when the match is already active" do
      match = match_with_image(status: "active", started_at: 1.minute.ago)
      sign_in_as other
      post join_match_path(match.code)
      expect(response).to redirect_to(match_path(match.code))
      expect(flash[:alert]).to match(/already started/i)
    end

    it "redirects with an alert when the lobby is at capacity" do
      match = match_with_image
      allow_any_instance_of(Match).to receive(:at_capacity?).and_return(true)
      sign_in_as other
      post join_match_path(match.code)
      expect(flash[:alert]).to match(/full/i)
    end
  end

  # ── POST /matches/:code/leave ─────────────────────────────────────────────────

  describe "POST /matches/:code/leave" do
    it "destroys the MatchPlayer row when leaving from the lobby" do
      match = match_with_image
      sign_in_as other
      post join_match_path(match.code)
      expect {
        post leave_match_path(match.code)
      }.to change(MatchPlayer, :count).by(-1)
      expect(response).to redirect_to(root_path)
    end

    it "stamps left_at instead of destroying when the match is active" do
      match = match_with_image(status: "active", started_at: 1.minute.ago)
      player = create(:match_player, match: match, user: other)
      sign_in_as other
      post leave_match_path(match.code)
      expect(player.reload.left_at).to be_present
      expect(MatchPlayer.exists?(player.id)).to be true
    end

    it "redirects to root when the user is not in the match" do
      match = match_with_image
      sign_in_as other
      post leave_match_path(match.code)
      expect(response).to redirect_to(root_path)
    end
  end

  # ── POST /matches/:code/start ─────────────────────────────────────────────────

  describe "POST /matches/:code/start" do
    it "sets match to active and creates the first round when called by the host" do
      match = match_with_image
      create(:match_player, match: match, user: host)
      sign_in_as host
      perform_enqueued_jobs do
        post start_match_path(match.code)
      end
      expect(match.reload.status).to eq("active")
      expect(match.match_rounds.count).to eq(1)
    end

    it "redirects non-host users back to the lobby with an alert" do
      match = match_with_image
      create(:match_player, match: match, user: other)
      sign_in_as other
      post start_match_path(match.code)
      expect(response).to redirect_to(match_path(match.code))
      expect(flash[:alert]).to be_present
    end
  end

  # ── GET /matches/:code/state.json ─────────────────────────────────────────────

  describe "GET /matches/:code/state.json" do
    let(:match)  { match_with_image(status: "active", started_at: 1.minute.ago) }
    let(:image)  { match.image_set.images.first }
    let!(:player) { create(:match_player, match: match, user: host) }

    before do
      create(:match_round, match: match, index: 1, image: image,
             answer_latitude: 48.8566, answer_longitude: 2.3522,
             deadline_at: 1.minute.from_now)
      sign_in_as host
    end

    it "returns a JSON payload with the correct shape" do
      get state_match_path(match.code, format: :json)
      expect(response).to have_http_status(:ok)
      body = response.parsed_body
      expect(body).to include("match", "you", "players")
    end

    it "NEVER leaks answer coordinates in current_round during a live round" do
      get state_match_path(match.code, format: :json)
      current_round = response.parsed_body["current_round"]
      expect(current_round).not_to have_key("answer_latitude")
      expect(current_round).not_to have_key("answer_longitude")
    end

    it "exposes answer coordinates in last_round_result once the round ends" do
      round = match.match_rounds.last
      round.update!(ended_at: 1.second.ago)
      get state_match_path(match.code, format: :json)
      result = response.parsed_body["last_round_result"]
      expect(result).to be_present
      expect(result["answer"]).to include("lat", "lng")
    end

    it "includes locked_in status for each player" do
      get state_match_path(match.code, format: :json)
      players = response.parsed_body["players"]
      expect(players.first).to have_key("locked_in")
    end
  end

  # ── POST /matches/:code/guess ─────────────────────────────────────────────────

  describe "POST /matches/:code/guess" do
    let(:match)   { match_with_image(status: "active", started_at: 1.minute.ago) }
    let(:image)   { match.image_set.images.first }
    let!(:player) { create(:match_player, match: match, user: host) }
    let!(:round) do
      create(:match_round, match: match, index: 1, image: image,
             answer_latitude: 48.8566, answer_longitude: 2.3522,
             deadline_at: 1.minute.from_now)
    end

    before { sign_in_as host }

    it "creates a MatchGuess and returns JSON ok" do
      expect {
        post guess_match_path(match.code), params: { lat: 48.0, lng: 2.0 },
             as: :json
      }.to change(MatchGuess, :count).by(1)
      expect(response).to have_http_status(:ok)
      expect(response.parsed_body["ok"]).to be true
    end

    it "returns 409 when the round has already ended" do
      round.update!(ended_at: 1.second.ago)
      post guess_match_path(match.code), params: { lat: 48.0, lng: 2.0 }, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "returns 409 when the round deadline has passed" do
      round.update!(deadline_at: 1.second.ago)
      post guess_match_path(match.code), params: { lat: 48.0, lng: 2.0 }, as: :json
      expect(response).to have_http_status(:conflict)
    end

    it "returns 422 for out-of-range coordinates" do
      post guess_match_path(match.code), params: { lat: 999, lng: 999 }, as: :json
      expect(response).to have_http_status(:unprocessable_entity)
    end

    it "returns 403 for a user not in the match" do
      sign_in_as other
      post guess_match_path(match.code), params: { lat: 48.0, lng: 2.0 }, as: :json
      expect(response).to have_http_status(:forbidden)
    end

    it "ends the round early when all active players have guessed" do
      perform_enqueued_jobs do
        post guess_match_path(match.code), params: { lat: 48.0, lng: 2.0 }, as: :json
      end
      expect(round.reload.ended_at).to be_present
    end
  end

  # ── GET /matches/:code/results ─────────────────────────────────────────────────

  describe "GET /matches/:code/results" do
    it "renders the results page with standings sorted highest score first" do
      match = match_with_image(status: "finished", started_at: 10.minutes.ago,
                               finished_at: Time.current)
      p_alice = create(:match_player, match: match, user: host, total_score: 5000)
      p_bob   = create(:match_player, match: match, user: other, total_score: 3000)
      sign_in_as host
      get results_match_path(match.code)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(host.username)
    end
  end

  # ── DELETE /matches/:code ─────────────────────────────────────────────────────

  describe "DELETE /matches/:code" do
    it "destroys the match when called by the host" do
      match = match_with_image
      sign_in_as host
      expect {
        delete match_path(match.code)
      }.to change(Match, :count).by(-1)
      expect(response).to redirect_to(root_path)
    end

    it "redirects non-host users with an alert" do
      match = match_with_image
      sign_in_as other
      delete match_path(match.code)
      expect(response).to redirect_to(match_path(match.code))
      expect(flash[:alert]).to match(/host/i)
    end
  end
end
