Feature: Match Gameplay
  As a player in an active match
  I want to submit guesses and have rounds scored correctly
  So that all players see fair, server-authoritative results

  Background:
    Given a verified user "alice" exists
    And a verified user "bob" exists

  Scenario: Player submits a valid guess during an active round
    Given an active match with code "PLAY01" exists with "alice" as host
    And "alice" is an active player in match "PLAY01"
    And match "PLAY01" has an active round with a future deadline
    And I am signed in as "alice"
    When I submit a guess of latitude 48.8566 and longitude 2.3522 for match "PLAY01"
    Then the response should indicate success
    And a match guess should be recorded for "alice" in match "PLAY01"

  Scenario: Round ends early when all active players have guessed
    Given an active match with code "PLAY02" exists with "alice" as host
    And "alice" is an active player in match "PLAY02"
    And match "PLAY02" has an active round with a future deadline
    And I am signed in as "alice"
    When I submit a guess of latitude 51.5074 and longitude -0.1278 for match "PLAY02"
    Then the current round of match "PLAY02" should be ended
    And the guess for "alice" in match "PLAY02" should have a score

  Scenario: Guess is rejected when the round deadline has passed
    Given an active match with code "PLAY03" exists with "alice" as host
    And "alice" is an active player in match "PLAY03"
    And match "PLAY03" has an expired round
    And I am signed in as "alice"
    When I submit a guess of latitude 48.0 and longitude 2.0 for match "PLAY03"
    Then the response should indicate a conflict

  Scenario: Guess is rejected for coordinates outside valid range
    Given an active match with code "PLAY04" exists with "alice" as host
    And "alice" is an active player in match "PLAY04"
    And match "PLAY04" has an active round with a future deadline
    And I am signed in as "alice"
    When I submit a guess of latitude 999 and longitude 999 for match "PLAY04"
    Then the response should indicate unprocessable entity

  Scenario: Anti-cheat — live state does not expose answer coordinates
    Given an active match with code "PLAY05" exists with "alice" as host
    And "alice" is an active player in match "PLAY05"
    And match "PLAY05" has an active round with a future deadline
    And I am signed in as "alice"
    When I poll the state of match "PLAY05"
    Then the state JSON should not contain answer coordinates in current_round
    And the state JSON should contain image_url in current_round

  Scenario: Ended round exposes the answer in last_round_result
    Given an active match with code "PLAY06" exists with "alice" as host
    And "alice" is an active player in match "PLAY06"
    And match "PLAY06" has an ended round
    And I am signed in as "alice"
    When I poll the state of match "PLAY06"
    Then the state JSON should contain answer coordinates in last_round_result

  Scenario: Timer job ends the round and scores guesses
    Given an active match with code "TIMER1" exists with "alice" as host
    And "alice" is an active player in match "TIMER1"
    And match "TIMER1" has an active round with a past deadline
    When the EndMatchRoundJob fires for the current round of match "TIMER1"
    Then the current round of match "TIMER1" should be ended
    And the match "TIMER1" status should be "finished"
