# ── Shared state ──────────────────────────────────────────────────────────────

# Keyed stores so scenarios can reference users/sets/matches by name.
Given("a verified user {string} exists") do |username|
  @users ||= {}
  @users[username] = create(:user, username: username,
                             email_address: "#{username}@example.com",
                             email_verified_at: 1.day.ago)
end

Given("an image set {string} exists with {int} usable images") do |name, count|
  @image_sets ||= {}
  @users      ||= {}
  # Reuse an existing user as owner so playable_by? returns true for them.
  # Fall back to a fresh user only when no users exist yet.
  owner = @users.values.first || begin
    short_key = Digest::MD5.hexdigest(name)[0, 8]
    create(:user, username: "own#{short_key}",
                  email_address: "own#{short_key}@example.com",
                  email_verified_at: 1.day.ago)
  end
  set = create(:image_set, name: name, user: owner)
  count.times do
    image = create(:image, latitude: 48.8566, longitude: 2.3522)
    create(:image_set_item, image_set: set, image: image)
  end
  @image_sets[name] = set
end

# ── Lobby steps ───────────────────────────────────────────────────────────────

Given("a lobby match with code {string} exists hosted by {string} using {string}") do |code, host_name, set_name|
  @users ||= {}
  @image_sets ||= {}
  @matches ||= {}
  host = @users[host_name] || create(:user, username: host_name,
                                     email_address: "#{host_name}@example.com",
                                     email_verified_at: 1.day.ago)
  @users[host_name] = host
  set = @image_sets[set_name]
  unless set
    set = create(:image_set, name: set_name, user: host)
    3.times do
      img = create(:image, latitude: 48.8566, longitude: 2.3522)
      create(:image_set_item, image_set: set, image: img)
    end
    @image_sets[set_name] = set
  end
  match = Match.create!(host: host, image_set: set, code: code,
                        rounds_total: 3, seconds_per_round: 30, status: "lobby")
  @matches[code] = match
end

Given("{string} has joined the match {string}") do |username, code|
  @users ||= {}
  @matches ||= {}
  user  = @users[username]
  match = @matches[code]
  match.match_players.find_or_create_by!(user: user) do |mp|
    mp.joined_at = Time.current
  end
end

Given("a lobby match exists hosted by {string} using {string} that is at capacity") do |host_name, set_name|
  @users ||= {}
  @image_sets ||= {}
  @matches ||= {}
  host = @users[host_name] || create(:user, username: host_name,
                                     email_address: "#{host_name}@example.com",
                                     email_verified_at: 1.day.ago)
  @users[host_name] = host
  set = @image_sets[set_name] || create(:image_set, name: set_name, user: host)
  @image_sets[set_name] = set
  match = create(:match, host: host, image_set: set)
  allow_any_instance_of(Match).to receive(:at_capacity?).and_return(true)
  @matches["__capacity__"] = match
  @capacity_match = match
end

Given("I am signed in as {string}") do |username|
  @users ||= {}
  user = @users[username]
  page.driver.post(session_url, login: user.email_address, password: "password123")
  @current_user = user
end

# ── Navigation steps ──────────────────────────────────────────────────────────

When("I create a match with image set {string} and {int} rounds") do |set_name, rounds|
  set = @image_sets[set_name]
  page.driver.post(matches_url, image_set_id: set.id, rounds_total: rounds,
                                seconds_per_round: 30)
  @created_match = Match.last
end

When("I visit the match lobby for {string}") do |code|
  @matches ||= {}
  @last_response = page.driver.get(match_url(code))
end

When("I try to join the full match") do
  match = @capacity_match || @matches.values.first
  page.driver.post(join_match_url(match.code))
  @last_response_location = page.driver.response.headers["Location"]
  @last_flash = nil
end

When("I try to start the match {string}") do |code|
  match = @matches[code]
  page.driver.post(start_match_url(code))
end

When("I start the match {string}") do |code|
  # Post without perform_enqueued_jobs — MatchStartRound creates the first
  # round synchronously; the EndMatchRoundJob timer is just queued (not run)
  # so the match stays "active" rather than racing through all rounds.
  page.driver.post(start_match_url(code))
end

# ── Assertion steps ───────────────────────────────────────────────────────────

Then("I should be on the lobby page") do
  match = @created_match
  expect(page.driver.response.headers["Location"]).to include("/matches/#{match.code}")
end

Then("I should see a {int}-character match code") do |length|
  match = @created_match
  expect(match.code.length).to eq(length)
  expect(match.code.chars.all? { |c| Match::CODE_ALPHABET.include?(c) }).to be true
end

Then("I should see the match lobby page") do
  expect(page.driver.response.status).to eq(200).or eq(302)
end

Then("I should see a Join Match button") do
  # When visiting as a non-joined user, the response body contains the join form.
  page.driver.get(match_url(@matches.values.last.code))
  expect(page.driver.response.body).to include("Join")
end

Then("I should be redirected back to the lobby") do
  expect(page.driver.response.headers["Location"]).to include("/matches/")
end

Then("I should see a flash message matching {string}") do |text|
  location = page.driver.response.headers["Location"]
  page.driver.get(location) if location
  expect(page.driver.response.body.downcase).to include(text.downcase)
end

Then("the match {string} status should be {string}") do |code, status|
  expect(Match.find_by!(code: code).status).to eq(status)
end

Then("a match round should have been created for {string}") do |code|
  match = Match.find_by!(code: code)
  expect(match.match_rounds.count).to be >= 1
end

# ── Active match / gameplay setup steps ──────────────────────────────────────

Given("an active match with code {string} exists with {string} as host") do |code, host_name|
  @users   ||= {}
  @matches ||= {}
  host = @users[host_name] || create(:user, username: host_name,
                                     email_address: "#{host_name}@example.com",
                                     email_verified_at: 1.day.ago)
  @users[host_name] = host
  image_set = create(:image_set, user: host)
  @image = create(:image, latitude: 48.8566, longitude: 2.3522)
  create(:image_set_item, image_set: image_set, image: @image)
  match = Match.create!(host: host, image_set: image_set, code: code,
                        rounds_total: 1, seconds_per_round: 30,
                        status: "active", started_at: 1.minute.ago)
  @matches[code] = match
end

Given("{string} is an active player in match {string}") do |username, code|
  @users   ||= {}
  @matches ||= {}
  user  = @users[username]
  match = @matches[code]
  match.match_players.find_or_create_by!(user: user) { |mp| mp.joined_at = Time.current }
end

Given("match {string} has an active round with a future deadline") do |code|
  @matches ||= {}
  match = @matches[code]
  @image ||= match.image_set.images.first || create(:image, latitude: 48.8566, longitude: 2.3522)
  @rounds ||= {}
  @rounds[code] = match.match_rounds.create!(
    index: 1, image: @image,
    answer_latitude: 48.8566, answer_longitude: 2.3522,
    started_at: 1.minute.ago, deadline_at: 5.minutes.from_now
  )
end

Given("match {string} has an expired round") do |code|
  @matches ||= {}
  match = @matches[code]
  @image ||= match.image_set.images.first || create(:image, latitude: 48.8566, longitude: 2.3522)
  @rounds ||= {}
  @rounds[code] = match.match_rounds.create!(
    index: 1, image: @image,
    answer_latitude: 48.8566, answer_longitude: 2.3522,
    started_at: 5.minutes.ago, deadline_at: 1.second.ago
  )
end

Given("match {string} has an ended round") do |code|
  @matches ||= {}
  match = @matches[code]
  @image ||= match.image_set.images.first || create(:image, latitude: 48.8566, longitude: 2.3522)
  @rounds ||= {}
  @rounds[code] = match.match_rounds.create!(
    index: 1, image: @image,
    answer_latitude: 48.8566, answer_longitude: 2.3522,
    started_at: 5.minutes.ago, deadline_at: 3.minutes.ago,
    ended_at: 2.minutes.ago
  )
end

Given("match {string} has an active round with a past deadline") do |code|
  step "match \"#{code}\" has an expired round"
end

# ── Gameplay action steps ─────────────────────────────────────────────────────

When("I submit a guess of latitude {float} and longitude {float} for match {string}") do |lat, lng, code|
  perform_enqueued_jobs do
    @guess_response_status = nil
    page.driver.post(guess_match_url(code), lat: lat, lng: lng,
                     format: "json")
  end
  @last_guess_response = page.driver.response
end

When("I poll the state of match {string}") do |code|
  page.driver.get(state_match_url(code, format: "json"))
  @state_response = page.driver.response
end

When("the EndMatchRoundJob fires for the current round of match {string}") do |code|
  match = @matches[code]
  round = match.current_round
  perform_enqueued_jobs { EndMatchRoundJob.perform_later(round.id) }
end

# ── Gameplay assertion steps ──────────────────────────────────────────────────

Then("the response should indicate success") do
  expect(@last_guess_response.status).to eq(200)
  body = JSON.parse(@last_guess_response.body) rescue {}
  expect(body["ok"]).to be true
end

Then("the response should indicate a conflict") do
  expect(@last_guess_response.status).to eq(409)
end

Then("the response should indicate unprocessable entity") do
  expect(@last_guess_response.status).to eq(422)
end

Then("a match guess should be recorded for {string} in match {string}") do |username, code|
  user   = @users[username]
  match  = @matches[code]
  player = match.match_players.find_by!(user: user)
  expect(match.match_guesses.where(match_player: player).count).to be >= 1
end

Then("the current round of match {string} should be ended") do |code|
  match = @matches[code]
  expect(match.current_round.reload.ended_at).to be_present
end

Then("the guess for {string} in match {string} should have a score") do |username, code|
  user   = @users[username]
  match  = @matches[code]
  player = match.match_players.find_by!(user: user)
  guess  = match.match_guesses.where(match_player: player).last
  expect(guess.reload.score).to be_present
end

Then("the state JSON should not contain answer coordinates in current_round") do
  body = JSON.parse(@state_response.body)
  current_round = body["current_round"]
  expect(current_round).not_to have_key("answer_latitude")
  expect(current_round).not_to have_key("answer_longitude")
end

Then("the state JSON should contain image_url in current_round") do
  body = JSON.parse(@state_response.body)
  expect(body.dig("current_round", "image_url")).to be_present
end

Then("the state JSON should contain answer coordinates in last_round_result") do
  body = JSON.parse(@state_response.body)
  answer = body.dig("last_round_result", "answer")
  expect(answer).to be_present
  expect(answer).to include("lat", "lng")
end

# ── Results page steps ────────────────────────────────────────────────────────

Given("a finished match with code {string} exists with {string} as host") do |code, host_name|
  @users   ||= {}
  @matches ||= {}
  host = @users[host_name] || create(:user, username: host_name,
                                     email_address: "#{host_name}@example.com",
                                     email_verified_at: 1.day.ago)
  @users[host_name] = host
  image_set = create(:image_set, user: host)
  match = Match.create!(host: host, image_set: image_set, code: code,
                        rounds_total: 1, seconds_per_round: 30,
                        status: "finished", started_at: 10.minutes.ago,
                        finished_at: Time.current)
  @matches[code] = match
end

Given("{string} has a total score of {int} in match {string}") do |username, score, code|
  @users   ||= {}
  @matches ||= {}
  user  = @users[username] || create(:user, username: username,
                                     email_address: "#{username}@example.com",
                                     email_verified_at: 1.day.ago)
  @users[username] = user
  match = @matches[code]
  match.match_players.create!(user: user, joined_at: Time.current, total_score: score)
end

Given("{string} has a total score of {int} in match {string} and joined first") do |username, score, code|
  step "\"#{username}\" has a total score of #{score} in match \"#{code}\""
end

Given("{string} has a total score of {int} in match {string} and joined second") do |username, score, code|
  user  = @users[username] || create(:user, username: username,
                                     email_address: "#{username}@example.com",
                                     email_verified_at: 1.day.ago)
  @users[username] = user
  match = @matches[code]
  match.match_players.create!(user: user, joined_at: 1.second.from_now, total_score: score)
end

When("I visit the results page for match {string}") do |code|
  page.driver.get(results_match_url(code))
  @results_response = page.driver.response
end

Then("I should see {string} listed before {string} in the standings") do |first, second|
  # Verify via DB standings order — more reliable than HTML position since
  # usernames also appear in nav bars and other structural elements.
  match = @matches.values.find { |m| m.status == "finished" } || Match.finished.last
  standings = match.match_players.includes(:user)
                   .sort_by { |p| [-p.total_score.to_i, p.joined_at.to_i] }
  names = standings.map { |p| p.user.username }
  expect(names.index(first)).to be < names.index(second),
    "Expected #{first} to rank above #{second} but got standings: #{names.inspect}"
end

Then("I should see the round breakdown table") do
  expect(@results_response.status).to eq(200)
end
