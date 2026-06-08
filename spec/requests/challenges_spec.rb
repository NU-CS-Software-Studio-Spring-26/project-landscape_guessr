require "rails_helper"

RSpec.describe "Challenges", type: :request do
  let(:challenger) { create(:user) }
  let(:other)      { create(:user) }
  let(:image_set)  { create(:image_set, user: challenger) }

  # Build a challenge with 5 challenge_images (the required minimum).
  def challenge_with_images(owner: challenger)
    challenge = create(:challenge, challenger: owner)
    5.times.with_index(1) do |_, pos|
      image = create(:image, latitude: 48.8566 + pos * 0.1, longitude: 2.3522)
      create(:challenge_image, challenge: challenge, image: image, position: pos)
    end
    challenge
  end

  # Build an image_set with `n` reachable items (image coords set, url present).
  def image_set_with_items(n, owner: challenger)
    set = create(:image_set, user: owner)
    n.times do
      image = create(:image, latitude: 48.8566, longitude: 2.3522,
                     url: "https://example.com/img#{SecureRandom.hex(4)}.jpg")
      create(:image_set_item, image_set: set, image: image)
    end
    set
  end

  # ── Authentication guard ─────────────────────────────────────────────────────

  describe "GET /challenges" do
    it "redirects guests to the login page" do
      get challenges_path
      expect(response).to redirect_to(new_session_path)
    end

    it "returns 200 for signed-in users" do
      sign_in_as challenger
      get challenges_path
      expect(response).to have_http_status(:ok)
    end
  end

  # ── GET /challenges/:token (show) ─────────────────────────────────────────────

  describe "GET /challenges/:token" do
    it "returns 200 for a valid token" do
      challenge = challenge_with_images
      sign_in_as other
      get challenge_path(challenge.token)
      expect(response).to have_http_status(:ok)
    end

    it "redirects with a not-found message for an unknown token" do
      sign_in_as other
      get challenge_path("notreal0")
      expect(response).to redirect_to(root_path)
    end
  end

  # ── POST /challenges (create) ─────────────────────────────────────────────────

  describe "POST /challenges" do
    before { sign_in_as challenger }

    context "when the image set has enough reachable images" do
      let(:set) { image_set_with_items(5) }

      it "creates the challenge and 5 challenge_images, redirects to show" do
        expect {
          post challenges_path, params: { image_set_id: set.id }
        }.to change(Challenge, :count).by(1)
          .and change(ChallengeImage, :count).by(5)
        expect(response).to redirect_to(challenge_path(Challenge.last.token))
      end
    end

    context "when the image set has fewer than 5 reachable images" do
      let(:set) { image_set_with_items(2) }

      it "re-renders with 422 and does not create a challenge" do
        expect {
          post challenges_path, params: { image_set_id: set.id }
        }.not_to change(Challenge, :count)
        expect(response).to have_http_status(:unprocessable_entity)
        expect(response.body).to match(/not enough images/i)
      end
    end
  end

  # ── POST /challenges/:token/play ──────────────────────────────────────────────

  describe "POST /challenges/:token/play" do
    it "creates a new Game linked to the challenge and redirects to it" do
      challenge = challenge_with_images
      sign_in_as other
      expect {
        post play_challenge_path(challenge.token)
      }.to change(Game, :count).by(1)
      new_game = Game.last
      expect(new_game.challenge).to eq(challenge)
      expect(response).to redirect_to(game_path(new_game))
    end

    it "redirects to the existing in-progress game rather than creating a second one" do
      challenge = challenge_with_images
      sign_in_as other
      post play_challenge_path(challenge.token)
      first_game = Game.last
      expect {
        post play_challenge_path(challenge.token)
      }.not_to change(Game, :count)
      expect(response).to redirect_to(game_path(first_game))
    end

    it "creates a fresh game when the previous one was completed" do
      challenge = challenge_with_images
      sign_in_as other
      post play_challenge_path(challenge.token)
      Game.last.update!(status: "completed", completed_at: 1.minute.ago)
      expect {
        post play_challenge_path(challenge.token)
      }.to change(Game, :count).by(1)
    end
  end

  # ── DELETE /challenges/:token ─────────────────────────────────────────────────

  describe "DELETE /challenges/:token" do
    it "destroys the challenge when called by the challenger" do
      challenge = challenge_with_images
      sign_in_as challenger
      expect {
        delete challenge_path(challenge.token)
      }.to change(Challenge, :count).by(-1)
      expect(response).to redirect_to(challenges_path)
    end

    it "redirects non-challenger users with an alert" do
      challenge = challenge_with_images
      sign_in_as other
      expect {
        delete challenge_path(challenge.token)
      }.not_to change(Challenge, :count)
      expect(flash[:alert]).to be_present
    end
  end
end
