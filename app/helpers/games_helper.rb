module GamesHelper
  def leaderboard_sort_link(label, column)
    active = (params[:sort].presence || "score") == column
    desc   = (params[:direction].presence || "desc") == "desc"
    arrow  = active ? (desc ? " ▼" : " ▲") : ""
    link_to "#{label}#{arrow}", leaderboard_games_path(sort: column, direction: active && desc ? "asc" : "desc"),
            class: "hover:underline"
  end
end
