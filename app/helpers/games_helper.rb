module GamesHelper
  def leaderboard_sort_link(label, column)
    active = (params[:sort].presence || "score") == column
    asc    = (params[:direction].presence || "asc") == "asc"
    arrow  = active ? (asc ? " ▲" : " ▼") : ""
    link_to "#{label}#{arrow}", leaderboard_games_path(sort: column, direction: active && asc ? "desc" : "asc"),
            class: "hover:underline"
  end
end
