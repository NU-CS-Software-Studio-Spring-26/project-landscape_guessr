# Starts the next round of a Match. Picks a random image from the match's
# set that hasn't been used yet, stamps the deadline, and schedules the
# job that closes the round when the timer runs out.
#
# Returns the MatchRound, or nil if the set is exhausted (caller should
# finish the match in that case).
class MatchStartRound
  def self.call(match:)
    next_index = (match.match_rounds.maximum(:index) || 0) + 1
    return nil if next_index > match.rounds_total

    used_image_ids = match.match_rounds.pluck(:image_id)
    item = match.image_set.image_set_items
      .with_usable_coords
      .where.not(image_id: used_image_ids)
      .order(Arel.sql("RANDOM()"))
      .first

    return nil unless item

    now = Time.current
    round = match.match_rounds.create!(
      index: next_index,
      image_id: item.image_id,
      answer_latitude:  item.answer_lat,
      answer_longitude: item.answer_lng,
      started_at:  now,
      deadline_at: now + match.seconds_per_round.seconds
    )

    EndMatchRoundJob.set(wait: match.seconds_per_round.seconds).perform_later(round.id)
    round
  end
end
