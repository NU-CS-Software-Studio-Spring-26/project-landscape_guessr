module GamesHelper
  # Display a distance compactly: "847 m" under 1 km, "1.5 km" up to 10 km,
  # "47 km" beyond. Avoids rounding sub-km guesses to "0 km" and 1.x km
  # guesses up to "2 km".
  def format_distance_compact(km)
    if km < 1
      "#{(km * 1000).round} m"
    elsif km < 10
      rounded = km.round(1)
      "#{rounded == rounded.to_i ? rounded.to_i : rounded} km"
    else
      "#{number_with_delimiter(km.round)} km"
    end
  end

  def leaderboard_sort_link(label, column)
    active = (params[:sort].presence || "score") == column
    desc   = (params[:direction].presence || "desc") == "desc"
    arrow  = active ? (desc ? " ▼" : " ▲") : ""
    link_to "#{label}#{arrow}", leaderboard_games_path(sort: column, direction: active && desc ? "asc" : "desc", image_set_id: params[:image_set_id]),
            class: "hover:underline"
  end
end
