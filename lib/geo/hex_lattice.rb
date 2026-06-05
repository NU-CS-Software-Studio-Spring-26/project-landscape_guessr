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

      # A fixed-radius (30km) lattice over a continent-sized bbox is tens of
      # thousands of points. Capping that by truncation strands every probe in
      # the bottom rows — the US bbox's FIRST row alone (at American Samoa's
      # latitude, marching across the empty Pacific) is 200+ points, so the
      # continental US never gets a probe and the count comes back 0. Instead,
      # when the fixed-radius lattice would exceed max_probes, scale the RADIUS
      # up so ~max_probes circles still TILE the whole bbox (spacing stays
      # r*sqrt(3), so there are no coverage gaps). Small regions are untouched
      # (30km); a country gets a few hundred large covering circles spread
      # evenly across all of it.
      lat_step = radius_km * OVERLAP_FACTOR / 111.0
      lng_step = radius_km * OVERLAP_FACTOR / (111.0 * Math.cos(avg_lat * Math::PI / 180.0))
      full = ((max_lat - min_lat) / lat_step + 1) * ((max_lng - min_lng) / lng_step + 1)
      if full > max_probes
        radius_km *= Math.sqrt(full / max_probes)
        lat_step = radius_km * OVERLAP_FACTOR / 111.0
        lng_step = radius_km * OVERLAP_FACTOR / (111.0 * Math.cos(avg_lat * Math::PI / 180.0))
      end

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
      end

      # Scaling targets ~max_probes, but boundary slack can leave a few extra.
      # Thin by an even stride (not first(), which would re-introduce the
      # bottom-row bias the scaling just removed).
      return probes if probes.size <= max_probes
      stride = probes.size.to_f / max_probes
      (0...max_probes).map { |i| probes[(i * stride).floor] }
    end
  end
end
