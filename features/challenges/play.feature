Feature: Play a Challenge
  As an invited player
  I want to accept and play a challenge
  So that my score can be compared against others on the challenge leaderboard

  Background:
    Given a verified challenger "alice" exists
    And a verified player "bob" exists

  Scenario: Player starts playing a fresh challenge
    Given "alice" has created a challenge with 5 images
    And I am signed in as player "bob"
    When I play the challenge created by "alice"
    Then a new game should be created linked to the challenge
    And the game should use the same 5 images as the challenge
    And I should be redirected to the new game

  Scenario: Player resumes an in-progress challenge game
    Given "alice" has created a challenge with 5 images
    And "bob" has an in-progress game for "alice"'s challenge
    And I am signed in as player "bob"
    When I play the challenge created by "alice"
    Then no new game should be created
    And I should be redirected to "bob"'s existing in-progress game

  Scenario: Player can start a fresh game after completing the challenge
    Given "alice" has created a challenge with 5 images
    And "bob" has a completed game for "alice"'s challenge
    And I am signed in as player "bob"
    When I play the challenge created by "alice"
    Then a new game should be created linked to the challenge

  Scenario: Only the challenger can delete a challenge
    Given "alice" has created a challenge with 5 images
    And I am signed in as player "bob"
    When I try to delete "alice"'s challenge
    Then the challenge should still exist
    And I should see a flash message about authorization

  Scenario: Challenger can delete their own challenge
    Given "alice" has created a challenge with 5 images
    And I am signed in as challenger "alice"
    When I delete "alice"'s challenge
    Then the challenge should no longer exist

  Scenario: Completed scores appear on the challenge page leaderboard
    Given "alice" has created a challenge with 5 images
    And "alice" has completed the challenge with score 14000
    And "bob" has completed the challenge with score 8000
    And I am signed in as player "bob"
    When I visit the challenge page for "alice"'s challenge
    Then I should see "alice" listed before "bob" in the completed games
