# Ends a round: marks it ended, scores every guess against the answer,
# updates each player's running total, and either kicks off the next
# round or finishes the match.
#
# Idempotent. Both the timer job and the "everyone guessed" early-end
# path call this — whichever fires first wins, the other becomes a
# cheap DB lookup. The transactional row lock prevents two concurrent
# calls from double-scoring.
class MatchEndRound
  def self.call(round:)
    return if round.ended_at.present?

    MatchRound.transaction do
      locked = MatchRound.lock.find(round.id)
      return if locked.ended_at.present?
      locked.update!(ended_at: Time.current)
      score_guesses_for(locked)
    end

    match = round.match
    if match.match_rounds.count >= match.rounds_total
      match.update!(status: "finished", finished_at: Time.current)
    else
      MatchStartRound.call(match: match)
    end
  end

  def self.score_guesses_for(round)
    round.match_guesses.find_each do |g|
      dist_km = Game.haversine_km(
        g.latitude.to_f, g.longitude.to_f,
        round.answer_latitude.to_f, round.answer_longitude.to_f
      )
      score = Game.geoguessr_round_score(dist_km)
      g.update_columns(distance_km: dist_km, score: score)
      MatchPlayer.where(id: g.match_player_id)
                 .update_all([ "total_score = total_score + ?", score.to_i ])
    end
  end
end
