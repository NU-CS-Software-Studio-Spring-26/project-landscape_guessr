class EndMatchRoundJob < ApplicationJob
  queue_as :default

  def perform(round_id)
    round = MatchRound.find_by(id: round_id)
    return unless round
    MatchEndRound.call(round: round)
  end
end
