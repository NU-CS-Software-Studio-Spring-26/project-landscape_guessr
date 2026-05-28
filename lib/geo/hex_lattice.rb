module Geo
  # Generates a list of (lat, lng, radius_km) probe points covering a
  # bounding box with overlapping circles (a hex lattice). Used by
  # `CommonsImporter` to issue multiple `nearcoord:` queries when a
  # single 30km circle is too small to cover the region.
  #
  # Commons' `nearcoord:` operator takes a single (radius, lat, lng)
  # triple — it can't accept a bbox directly. Hex spacing of r * sqrt(3)
  # gives ~7% overlap so no point falls in a gap between circles.
  module HexLattice
    EARTH_R_KM = 6371.0
    OVERLAP_FACTOR = Math.sqrt(3)

    # bbox: { min_lat:, max_lat:, min_lng:, max_lng: }
    # radius_km: nearcoord radius for each probe point
    # Returns [{lat:, lng:, radius_km:}, ...]
    def self.probes_for_bbox(bbox, radius_km: 30.0, max_probes: 200)
      min_lat, max_lat = bbox[:min_lat], bbox[:max_lat]
      min_lng, max_lng = bbox[:min_lng], bbox[:max_lng]

      span_lat_km = (max_lat - min_lat) * 111.0
      avg_lat = (min_lat + max_lat) / 2.0
      span_lng_km = (max_lng - min_lng) * 111.0 * Math.cos(avg_lat * Math::PI / 180.0)

      # Single probe sufficient when bbox diagonal < 2r.
      if span_lat_km <= radius_km * 1.5 && span_lng_km <= radius_km * 1.5
        return [ { lat: avg_lat, lng: (min_lng + max_lng) / 2.0, radius_km: radius_km } ]
      end

      # Hex lattice: rows offset by r*sqrt(3); cols offset by r*sqrt(3)*sqrt(3)/2 = 1.5r.
      # Convert km spacing back to degrees.
      lat_step = radius_km * OVERLAP_FACTOR / 111.0
      lng_step = radius_km * OVERLAP_FACTOR / (111.0 * Math.cos(avg_lat * Math::PI / 180.0))

      probes = []
      lat = min_lat
      row = 0
      while lat <= max_lat + lat_step
        col_offset = row.odd? ? lng_step / 2.0 : 0.0
        lng = min_lng + col_offset
        while lng <= max_lng + lng_step
          probes << { lat: lat, lng: lng, radius_km: radius_km }
          lng += lng_step
        end
        lat += lat_step
        row += 1
        break if probes.size >= max_probes
      end
      probes.first(max_probes)
    end
  end
end
