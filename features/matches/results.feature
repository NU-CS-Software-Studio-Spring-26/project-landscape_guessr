Feature: Match Results
  As a player
  I want to see final standings after a match ends
  So that I know who won and how everyone scored

  Background:
    Given a verified user "alice" exists
    And a verified user "bob" exists

  Scenario: Final standings are ranked by total score descending
    Given a finished match with code "DONE01" exists with "alice" as host
    And "alice" has a total score of 5000 in match "DONE01"
    And "bob" has a total score of 3000 in match "DONE01"
    And I am signed in as "alice"
    When I visit the results page for match "DONE01"
    Then I should see "alice" listed before "bob" in the standings

  Scenario: Tied scores are broken by earliest join time
    Given a finished match with code "DONE02" exists with "alice" as host
    And "alice" has a total score of 4000 in match "DONE02" and joined first
    And "bob" has a total score of 4000 in match "DONE02" and joined second
    And I am signed in as "alice"
    When I visit the results page for match "DONE02"
    Then I should see "alice" listed before "bob" in the standings

  Scenario: Results page shows each round's score breakdown
    Given a finished match with code "DONE03" exists with "alice" as host
    And "alice" has a total score of 3500 in match "DONE03"
    And I am signed in as "alice"
    When I visit the results page for match "DONE03"
    Then I should see the round breakdown table
