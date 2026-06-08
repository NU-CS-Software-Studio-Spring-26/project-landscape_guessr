Feature: Create a Challenge
  As a logged-in player
  I want to create challenges from an image set
  So that I can share a fixed set of images with other players asynchronously

  Background:
    Given a verified challenger "alice" exists
    And a verified player "bob" exists

  Scenario: Challenger creates a challenge and receives a share link
    Given the image set "World" has 5 reachable images owned by "alice"
    And I am signed in as challenger "alice"
    When I create a challenge using image set "World"
    Then a challenge should be created with 5 challenge images
    And I should be redirected to the challenge page
    And the challenge page should show a share link

  Scenario: Creation fails when the set has fewer than 5 reachable images
    Given the image set "Tiny" has 2 reachable images owned by "alice"
    And I am signed in as challenger "alice"
    When I create a challenge using image set "Tiny"
    Then no challenge should be created
    And the response should show "Not enough images"

  Scenario: All 5 challenge images use coordinates from the source set
    Given the image set "Geolocated" has 5 reachable images owned by "alice"
    And I am signed in as challenger "alice"
    When I create a challenge using image set "Geolocated"
    Then each challenge image should have answer coordinates set
