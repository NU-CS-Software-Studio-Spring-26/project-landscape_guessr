module ApplicationHelper
  # Returns a URL suitable for use in an <img> src.
  # For Active Storage uploads: returns the blob URL served by Rails.
  # For Wikimedia/external URL images: returns the URL, optionally with a
  # CDN width hint appended as a query param (?width=N).
  def image_src(image, width: nil)
    if image.respond_to?(:photo) && image.photo.attached?
      url_for(image.photo)
    elsif image.respond_to?(:url) && image.url.present?
      width ? "#{image.url}?width=#{width}" : image.url
    end
  end

  # Server-renders a date as a fallback, then swaps to the user's local
  # date via a Stimulus controller. Date-only — no time or timezone.
  def local_date_tag(time)
    return "" unless time
    content_tag :time, time.to_date.to_fs(:long),
      datetime: time.iso8601,
      data: { controller: "local-time" }
  end
end
