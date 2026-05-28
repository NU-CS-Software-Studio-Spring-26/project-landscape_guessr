# Image attribution + source labeling helpers.
#
# Two modes for `attribution_for`:
#   :in_round — minimal cheat surface (shown DURING a game round). Source
#               name only — never a clickable link or image-page URL that
#               could reveal coords.
#   :full     — post-round / library view. Source name + author + license
#               + link to the file's home page on Commons/Mapillary.
#
# Mapillary attribution links go to `mapillary.com` (homepage), NOT the
# image page — image-page URLs encode the lat/lng in the query string
# which would leak the answer during a round.
module AttributionHelper
  SOURCE_LABELS = {
    "wikidata"  => "Wikidata / Wikimedia",
    "commons"   => "Wikimedia Commons",
    "mapillary" => "Mapillary"
  }.freeze

  def source_label(source)
    SOURCE_LABELS[source.to_s] || "Other"
  end

  # Small pill rendered on image_set show + ai_result preview.
  def source_pill(source)
    return nil if source.blank?
    content_tag :span,
      "Source: #{source_label(source)}",
      class: "inline-flex items-center gap-1 text-xs px-2 py-1 rounded-full " \
             "bg-forest-50 text-forest-700 border border-forest-200"
  end

  def attribution_for(image, mode: :full)
    return "".html_safe unless image
    source = image.try(:external_source).to_s
    case source
    when "mapillary"
      mapillary_attribution(image, mode: mode)
    when "commons", "wikidata", ""
      commons_wikidata_attribution(image, mode: mode)
    else
      content_tag(:span, "Photo: #{source_label(source)}", class: "text-xs")
    end
  end

  def mapillary_attribution(image, mode:)
    if mode == :in_round
      content_tag(:span, "Mapillary", class: "text-xs")
    else
      author = image.try(:author).presence
      parts = [ "Mapillary" ]
      parts << "by user #{author}" if author
      parts << "CC-BY-SA 4.0"
      content_tag(:span, class: "text-xs") do
        text = parts.join(" · ")
        safe_join([ text, " ", link_to("Mapillary.com", "https://www.mapillary.com", target: "_blank", rel: "noopener nofollow", class: "underline") ])
      end
    end
  end

  def commons_wikidata_attribution(image, mode:)
    if mode == :in_round
      content_tag(:span, "Wikimedia Commons", class: "text-xs")
    else
      author = image.try(:author).presence
      license = image.try(:license).presence
      parts = [ "Wikimedia Commons" ]
      parts << "by #{author}" if author
      parts << license if license
      content_tag(:span, parts.join(" · "), class: "text-xs")
    end
  end
end
