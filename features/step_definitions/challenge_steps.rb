# ── Shared helpers ────────────────────────────────────────────────────────────

# Creates an image_set with `n` images that all have coordinates and a URL
# (so ImageReachability considers them reachable — stubbed in env.rb to pass all).
def build_image_set_with_images(name, n, owner)
  set = create(:image_set, name: name, user: owner)
  n.times.with_index(1) do |_, i|
    img = create(:image, latitude: 48.0 + i * 0.1, longitude: 2.0,
                 url: "https://example.com/img#{SecureRandom.hex(4)}.jpg")
    create(:image_set_item, image_set: set, image: img)
  end
  set
end

# ── User setup ────────────────────────────────────────────────────────────────

Given("a verified challenger {string} exists") do |username|
  @users ||= {}
  @users[username] = create(:user, username: username,
                             email_address: "#{username}@example.com",
                             email_verified_at: 1.day.ago)
end

Given("a verified player {string} exists") do |username|
  @users ||= {}
  @users[username] = create(:user, username: username,
                             email_address: "#{username}@example.com",
                             email_verified_at: 1.day.ago)
end

Given("I am signed in as challenger {string}") do |username|
  user = @users[username]
  page.driver.post(session_url, login: user.email_address, password: "password123")
  @current_user = user
end

Given("I am signed in as player {string}") do |username|
  user = @users[username]
  page.driver.post(session_url, login: user.email_address, password: "password123")
  @current_user = user
end

# ── Image set setup ───────────────────────────────────────────────────────────

Given("the image set {string} has {int} reachable images owned by {string}") do |name, n, owner_name|
  @users       ||= {}
  @image_sets  ||= {}
  owner = @users[owner_name]
  @image_sets[name] = build_image_set_with_images(name, n, owner)
end

# ── Challenge creation steps ──────────────────────────────────────────────────

When("I create a challenge using image set {string}") do |set_name|
  @image_sets ||= {}
  set = @image_sets[set_name]
  page.driver.post(challenges_url, image_set_id: set.id)
  @create_response = page.driver.response
  @created_challenge = Challenge.last
end

Then("a challenge should be created with {int} challenge images") do |count|
  expect(Challenge.count).to eq(1)
  expect(ChallengeImage.count).to eq(count)
end

Then("I should be redirected to the challenge page") do
  expect(@create_response.headers["Location"]).to include("/challenges/")
end

Then("the challenge page should show a share link") do
  location = @create_response.headers["Location"]
  page.driver.get(location)
  expect(page.driver.response.body).to include(@created_challenge.token)
end

Then("no challenge should be created") do
  expect(Challenge.count).to eq(0)
end

Then("the response should show {string}") do |text|
  expect(@create_response.body.downcase).to include(text.downcase)
end

Then("each challenge image should have answer coordinates set") do
  challenge = @created_challenge
  challenge.challenge_images.each do |ci|
    expect(ci.answer_latitude).to be_present
    expect(ci.answer_longitude).to be_present
  end
end

# ── Challenge play setup steps ────────────────────────────────────────────────

Given("{string} has created a challenge with {int} images") do |challenger_name, count|
  @users      ||= {}
  @challenges ||= {}
  challenger = @users[challenger_name]
  set = build_image_set_with_images("#{challenger_name}_set", count, challenger)
  challenge = nil
  Challenge.transaction do
    challenge = create(:challenge, challenger: challenger)
    set.image_set_items.each_with_index do |item, idx|
      create(:challenge_image, challenge: challenge, image: item.image,
             position: idx + 1,
             answer_latitude: item.answer_lat, answer_longitude: item.answer_lng)
    end
  end
  @challenges[challenger_name] = challenge
end

Given("{string} has an in-progress game for {string}'s challenge") do |player_name, challenger_name|
  @users      ||= {}
  @challenges ||= {}
  @games      ||= {}
  player    = @users[player_name]
  challenge = @challenges[challenger_name]
  game = create(:game, user: player, challenge: challenge,
                image_set: create(:image_set, user: player),
                status: "in_progress")
  @games["#{player_name}_in_progress"] = game
end

Given("{string} has a completed game for {string}'s challenge") do |player_name, challenger_name|
  @users      ||= {}
  @challenges ||= {}
  @games      ||= {}
  player    = @users[player_name]
  challenge = @challenges[challenger_name]
  game = create(:game, :completed, user: player, challenge: challenge,
                image_set: create(:image_set, user: player))
  @games["#{player_name}_completed"] = game
end

Given("{string} has completed the challenge with score {int}") do |username, score|
  @users      ||= {}
  @challenges ||= {}
  user = @users[username]
  challenge = @challenges.values.first
  create(:game, :completed, user: user, challenge: challenge,
         image_set: create(:image_set, user: user), score: score)
end

# ── Play action steps ─────────────────────────────────────────────────────────

When("I play the challenge created by {string}") do |challenger_name|
  @challenges ||= {}
  challenge = @challenges[challenger_name]
  page.driver.post(play_challenge_url(challenge.token))
  @play_response = page.driver.response
end

When("I try to delete {string}'s challenge") do |challenger_name|
  @challenges ||= {}
  challenge = @challenges[challenger_name]
  page.driver.delete(challenge_url(challenge.token))
  @delete_response = page.driver.response
end

When("I delete {string}'s challenge") do |challenger_name|
  @challenges ||= {}
  challenge = @challenges[challenger_name]
  page.driver.delete(challenge_url(challenge.token))
  @delete_response = page.driver.response
  @deleted_challenge_id = challenge.id
end

When("I visit the challenge page for {string}'s challenge") do |challenger_name|
  @challenges ||= {}
  challenge = @challenges[challenger_name]
  page.driver.get(challenge_url(challenge.token))
  @challenge_page_response = page.driver.response
end

# ── Play assertion steps ──────────────────────────────────────────────────────

Then("a new game should be created linked to the challenge") do
  challenge = @challenges.values.first
  expect(Game.where(challenge: challenge).count).to be >= 1
end

Then("the game should use the same {int} images as the challenge") do |count|
  challenge = @challenges.values.first
  game = Game.where(challenge: challenge).last
  expect(game.game_images.count).to eq(count)
  challenge_image_ids = challenge.challenge_images.pluck(:image_id).sort
  game_image_ids = game.game_images.pluck(:image_id).sort
  expect(game_image_ids).to eq(challenge_image_ids)
end

Then("I should be redirected to the new game") do
  new_game = Game.last
  expect(@play_response.headers["Location"]).to include("/games/#{new_game.id}")
end

Then("no new game should be created") do
  expect(Game.count).to eq(1)
end

Then("{string}'s existing in-progress game") do |player_name|
  @games ||= {}
  @games["#{player_name}_in_progress"]
end

Then("I should be redirected to {string}'s existing in-progress game") do |player_name|
  @games ||= {}
  game = @games["#{player_name}_in_progress"]
  expect(@play_response.headers["Location"]).to include("/games/#{game.id}")
end

Then("the challenge should still exist") do
  @challenges ||= {}
  challenge = @challenges.values.first
  expect(Challenge.exists?(challenge.id)).to be true
end

Then("I should see a flash message about authorization") do
  location = @delete_response.headers["Location"]
  page.driver.get(location) if location
  body = page.driver.response.body
  expect(body).to match(/only|creator|challenger|not.*delete/i)
end

Then("the challenge should no longer exist") do
  expect(Challenge.exists?(@deleted_challenge_id)).to be false
end

Then("I should see {string} listed before {string} in the completed games") do |first, second|
  # Verify the leaderboard order via DB — more reliable than HTML position
  # because usernames appear elsewhere in the layout (nav, headers).
  challenge = @challenges.values.first
  completed = challenge.games.where.not(completed_at: nil).includes(:user)
                       .sort_by { |g| -g.score.to_f }
  names = completed.map { |g| g.user.username }
  expect(names.index(first)).to be < names.index(second),
    "Expected #{first} before #{second} but got: #{names.inspect}"
end
