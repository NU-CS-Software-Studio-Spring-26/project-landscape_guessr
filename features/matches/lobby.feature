Feature: Match Lobby
  As a player
  I want to create and join match lobbies
  So that I can play synchronous multiplayer rounds with others

  Background:
    Given a verified user "alice" exists
    And a verified user "bob" exists
    And an image set "World Landscapes" exists with 3 usable images

  Scenario: Host creates a match and sees the share code
    Given I am signed in as "alice"
    When I create a match with image set "World Landscapes" and 3 rounds
    Then I should be on the lobby page
    And I should see a 6-character match code

  Scenario: Another player joins via the share code
    Given a lobby match with code "ABCD23" exists hosted by "alice" using "World Landscapes"
    And I am signed in as "bob"
    When I visit the match lobby for "ABCD23"
    Then I should see the match lobby page
    And I should see a Join Match button

  Scenario: Lobby is full and a new player cannot join
    Given a lobby match exists hosted by "alice" using "World Landscapes" that is at capacity
    And I am signed in as "bob"
    When I try to join the full match
    Then I should be redirected back to the lobby
    And I should see a flash message matching "full"

  Scenario: Only the host can start the match
    Given a lobby match with code "ABCD23" exists hosted by "alice" using "World Landscapes"
    And "bob" has joined the match "ABCD23"
    And I am signed in as "bob"
    When I try to start the match "ABCD23"
    Then I should be redirected back to the lobby
    And I should see a flash message matching "host"

  Scenario: Host starts the match
    Given a lobby match with code "ABCD23" exists hosted by "alice" using "World Landscapes"
    And "alice" has joined the match "ABCD23"
    And I am signed in as "alice"
    When I start the match "ABCD23"
    Then the match "ABCD23" status should be "active"
    And a match round should have been created for "ABCD23"
