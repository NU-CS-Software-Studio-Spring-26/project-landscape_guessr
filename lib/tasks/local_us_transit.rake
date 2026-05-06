require "net/http"
require "uri"
require "json"

# Local-only: pulls US public-transit stations from Wikidata into a
# private ImageSet. Two flavors:
#
#   image_sets:fetch_us_transit          every station with image+coord
#                                        (~4500; includes defunct/closed)
#   image_sets:fetch_us_transit_active   drop stations whose P576
#                                        (dissolved) or P3999 (date of
#                                        official closure) is set
#                                        (~4000)
#
# Usage:
#   USER_EMAIL=you@example.com bin/rails image_sets:fetch_us_transit
#   USER_EMAIL=you@example.com bin/rails image_sets:fetch_us_transit_active
#   SET_NAME="My Transit" USER_EMAIL=... bin/rails image_sets:fetch_us_transit
#   bin/rails image_sets:fetch_us_transit[you@example.com]   # zsh: quote the [..]
#
# Idempotent: Image rows are find_or_create_by(url:), set membership is
# find_or_initialize_by(image:). Drop a set with:
#   ImageSet.find_by(name: "...", user: User.find_by(email_address: "...")).destroy!
# (image_set_items#after_destroy purges orphan Images.)

# Shared logic for both fetch_us_transit tasks. Keeping it in this rake
# file (rather than a sibling .rb under lib/tasks) means the whole script
# stays inside the gitignored /lib/tasks/local_*.rake pattern.
module LocalUSTransit
  # Top-level station types. We match each via wdt:P31/wdt:P279* so that
  # specific subclasses (NYC Subway station, Chicago 'L' station, people
  # mover station, elevated/underground metro station, ...) come in
  # automatically — without P279* we lost 1500+ stations to subclass
  # specificity, e.g. Mercer Island (Sound Transit) classed only as a
  # rapid-transit-station subclass instead of metro station directly.
  #
  # Each Q-ID was verified on https://www.wikidata.org/wiki/<id> — do
  # not edit blind. Past mistakes (now removed):
  #   Q4663385  is "former railway station"  (defunct by definition)
  #   Q27108230 is "campground"               (Mather, Sperry, Tamarack)
  #   Q174814   is "electrical substation"
  STATION_TYPES = %w[
    Q55488 railway-station
    Q928830 metro-station
    Q2175765 tram-stop
    Q494829 bus-station
    Q1335652 airport-railway-station
  ].each_slice(2).map(&:first).freeze

  # Countries to include. Q30 = United States, Q16 = Canada.
  COUNTRIES = %w[Q30 Q16].freeze

  # Definitive-closure P5817 (state of use) values to exclude. Items
  # without any P5817 statement also pass. Things like "closed to the
  # public" (Q55570340 — Cleveland RTA Settlers Landing while the
  # Waterfront Line is suspended) and "structure under reconstruction"
  # are kept on the assumption they're temporary rather than permanent.
  CLOSED_STATE_VALUES = %w[
    Q11639308 decommissioned
    Q63065035 abandoned
    Q56651571 out-of-service
    Q56556915 demolished-or-destroyed
    Q104664889 permanently-closed
    Q110435753 without-original-use
    Q811683 proposed-building-not-built
  ].each_slice(2).map(&:first).freeze

  # WMF asks bots to identify themselves with contact info — uncredited
  # scripts get rate-limited harder. The repo URL is the cheapest
  # globally-resolvable contact we've got.
  USER_AGENT = "landscape-guessr/local-us-transit (https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr) Ruby/#{RUBY_VERSION}".freeze

  # Reuse the seeder's filename heuristics for non-photo content. Probably
  # overkill for transit stations, but keeps maps/schematics out of the
  # gallery if any sneak through.
  NON_PHOTO_PATTERNS = [
    /ASTER|MODIS|Landsat|LANDSAT|Sentinel|MISR|Messtischblatt/i,
    /_map[._]|location[_\s-]map|relief[_\s-]map/i,
    /topographic|schematic|Harper.?s[_\s-]New/i
  ].freeze

  module_function

  def fetch!(args:, default_set_name:, active_only:)
    label = active_only ? "fetch_us_transit_active" : "fetch_us_transit"

    email = args[:user_email].presence || ENV["USER_EMAIL"].presence
    abort "[#{label}] pass a user email: USER_EMAIL=you@example.com bin/rails image_sets:#{label}" if email.blank?

    user = User.find_by(email_address: email)
    abort "[#{label}] no user with email_address=#{email.inspect}" unless user

    set_name = ENV["SET_NAME"].presence || default_set_name
    bindings = query_wikidata(active_only: active_only, label: label)

    # A station may appear multiple times (multiple P31 types or multiple
    # images). Keep the first row per Wikidata item URI.
    by_item = {}
    bindings.each do |b|
      iri = b.dig("item", "value")
      next if iri.nil? || by_item.key?(iri)
      by_item[iri] = b
    end
    puts "[#{label}] #{by_item.size} unique stations after dedupe"

    set = ImageSet.find_or_initialize_by(name: set_name, user: user)
    if set.new_record?
      set.visibility = "private"
      set.save!
      puts "[#{label}] Created private ImageSet \"#{set.name}\" (id=#{set.id}) owned by #{user.email_address}"
    else
      puts "[#{label}] Reusing existing ImageSet \"#{set.name}\" (id=#{set.id}, visibility=#{set.visibility})"
    end

    new_images = 0
    new_links = 0
    skipped_url = 0
    skipped_non_photo = 0
    skipped_coord = 0
    skipped_museum = 0

    by_item.each_value do |b|
      coord = b.dig("coord", "value")
      m = coord && coord.match(/Point\(([-\d.]+)\s+([-\d.]+)\)/)
      unless m
        skipped_coord += 1
        next
      end
      lng, lat = m[1].to_f, m[2].to_f

      url = b.dig("image", "value")&.sub(/\Ahttp:/, "https:")
      if url.blank? || url.length > 500 || !url.match?(/\.(jpe?g|png)\z/i)
        skipped_url += 1
        next
      end
      if NON_PHOTO_PATTERNS.any? { |p| url.match?(p) }
        skipped_non_photo += 1
        next
      end

      title = b.dig("itemLabel", "value").presence || "Untitled"
      # Drop bare Q-ID labels (Wikibase falls back to the entity id when
      # no English label exists) — looks ugly in the UI.
      title = "Untitled" if title.match?(/\AQ\d+\z/)

      # Active-only: drop items whose title says "Museum". Catches things
      # like "National New York Central Railroad Museum" and "Batavia
      # Depot Museum" that slipped through SPARQL because Wikidata
      # marks them P5817="in use" without recording closure. Word-
      # bounded so it doesn't hit "Museum Place" subway stops etc.
      if active_only && title.match?(/\bmuseum\b/i)
        skipped_museum += 1
        next
      end

      image = Image.find_or_create_by!(url: url) do |i|
        i.latitude  = lat
        i.longitude = lng
        i.title     = title
      end
      new_images += 1 if image.previously_new_record?

      item = set.image_set_items.find_or_initialize_by(image: image)
      if item.new_record?
        item.latitude  = lat
        item.longitude = lng
        item.save!
        new_links += 1
      end
    end

    puts "[#{label}] Done. Created #{new_images} new Image(s); linked #{new_links} new item(s) into the set."
    puts "[#{label}] Skipped: #{skipped_url} non-jpg/png URL(s), #{skipped_non_photo} filename-flagged non-photo(s), #{skipped_coord} bad-coord row(s), #{skipped_museum} \"Museum\" titles."
    puts "[#{label}] Set \"#{set.name}\" now has #{set.image_set_items.count} item(s). Open at /image_sets/#{set.id}."
  end

  # Query one station-type at a time and concatenate. WDQS has a 60s
  # hard query timeout — the union-of-six-types query was hitting EOF
  # mid-stream when MINUS slowed it past that ceiling. Per-type stays
  # well inside the budget, costs ~6 HTTP round-trips, and gives the
  # user real progress as it runs.
  def query_wikidata(active_only:, label:)
    flavor = active_only ? " (active-only)" : ""
    all_bindings = []
    STATION_TYPES.each_with_index do |type, idx|
      bindings = query_one_type(type: type, active_only: active_only, label: label, idx: idx + 1, total: STATION_TYPES.size, flavor: flavor)
      all_bindings.concat(bindings)
      # Small courtesy gap between requests so we don't trip the WDQS
      # per-IP rate limiter on the next call.
      sleep 0.5 unless idx == STATION_TYPES.size - 1
    end
    puts "[#{label}] Got #{all_bindings.size} rows total across #{STATION_TYPES.size} types"
    all_bindings
  end

  # MINUS plays nicer with the WDQS optimizer than FILTER NOT EXISTS at
  # this scale. Catches stations with explicit dissolution/closure
  # dates; stations merely classed as Q22808404 ("closed railway
  # station") with no date slip through — adding a P31/P279* walk for
  # those slows the query a lot.
  def query_one_type(type:, active_only:, label:, idx:, total:, flavor:)
    # Filters used when active_only is true. Layered because Wikidata
    # records "this station is closed" in many different ways:
    #
    # 1. P576 (dissolved/demolished date)            — formally gone
    # 2. P3999 (date of official closure)            — railway-specific
    # 3. P5817 (state of use) ≠ Q55654238 ("in use") — decommissioned,
    #    abandoned, out of service, under reconstruction, etc.
    # 4. P1435 (heritage designation) set AND no P81 (connecting line)
    #    AND no P1192 (connecting service) — the "repurposed depot"
    #    pattern: the building is on the NRHP and Wikidata still says
    #    "in use", but no current passenger line/service is recorded.
    #    Anchorage Depot (heritage-listed but actively served by Alaska
    #    Railroad) keeps its P1192 statements, so it stays.
    closed_values = CLOSED_STATE_VALUES.map { |q| "wd:#{q}" }.join(" ")
    countries     = COUNTRIES.map           { |q| "wd:#{q}" }.join(" ")

    # P5817 closure list is enumerated explicitly (rather than "anything
    # ≠ in use") so temporary states like "closed to the public"
    # (Q55570340 — Cleveland RTA Settlers Landing while the Waterfront
    # Line is suspended) and "structure under reconstruction" still
    # pass through.
    minus_clause = active_only ? <<~MINUS : ""
      MINUS { ?item wdt:P576  ?dissolved }
      MINUS { ?item wdt:P3999 ?closedAt }
      MINUS {
        ?item wdt:P5817 ?stateOfUse .
        VALUES ?stateOfUse { #{closed_values} }
      }
      MINUS {
        ?item wdt:P1435 ?heritage .
        FILTER NOT EXISTS { ?item wdt:P81   ?line }
        FILTER NOT EXISTS { ?item wdt:P1192 ?svc }
      }
    MINUS

    # P31/P279* — match the type itself plus every subclass. Without
    # the P279* walk we lose NYC subway stations (Q76940628), Chicago
    # 'L' (Q14641099), people movers (Q63979268), elevated/underground
    # metro (Q135932509/Q124416148), Mercer Island (Sound Transit
    # subclass), Makalapa (Honolulu Skyline elevated metro), etc. —
    # measured ~1500 station gain across the five top-level types.
    sparql = <<~SPARQL
      SELECT DISTINCT ?item ?itemLabel ?image ?coord WHERE {
        VALUES ?country { #{countries} }
        ?item wdt:P31/wdt:P279* wd:#{type} ;
              wdt:P17 ?country ;
              wdt:P18 ?image ;
              wdt:P625 ?coord .
        #{minus_clause}
        SERVICE wikibase:label { bd:serviceParam wikibase:language "en" }
      }
    SPARQL

    uri = URI("https://query.wikidata.org/sparql")
    response = nil
    started  = nil
    attempts = 0
    max_attempts = 3

    loop do
      attempts += 1
      req = Net::HTTP::Post.new(uri)
      req["Accept"]       = "application/sparql-results+json"
      req["Content-Type"] = "application/x-www-form-urlencoded"
      req["User-Agent"]   = USER_AGENT
      req.body = URI.encode_www_form(query: sparql)

      puts "[#{label}] Type #{idx}/#{total} (wd:#{type})#{flavor} attempt #{attempts}/#{max_attempts}..."
      started = Time.now
      begin
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 90) { |h| h.request(req) }
      rescue EOFError, Net::ReadTimeout, Net::OpenTimeout, Errno::ECONNRESET => e
        if attempts < max_attempts
          backoff = 5 * attempts
          puts "[#{label}] Network error (#{e.class}: #{e.message}). Backing off #{backoff}s..."
          sleep backoff
          next
        else
          abort "[#{label}] giving up on wd:#{type} after #{attempts} attempts: #{e.class}: #{e.message}"
        end
      end

      break if response.code == "200"

      retryable = response.code == "429" || response.code.start_with?("5")
      if retryable && attempts < max_attempts
        wait =
          if response.code == "429"
            (response["Retry-After"] || "60").to_i.clamp(5, 600)
          else
            # 5xx (typically 504 upstream timeout): brief exponential
            # backoff. Don't honor server-suggested wait — WDQS doesn't
            # send Retry-After on 5xx and a long sleep here just stalls.
            5 * attempts
          end
        puts "[#{label}] HTTP #{response.code} for wd:#{type}. Backing off #{wait}s..."
        sleep wait
      else
        abort "[#{label}] Wikidata returned #{response.code} for wd:#{type}: #{response.body[0, 200]}"
      end
    end

    bindings = JSON.parse(response.body).dig("results", "bindings") || []
    puts "[#{label}]   wd:#{type} → #{bindings.size} rows in #{(Time.now - started).round(1)}s"
    bindings
  end
end

namespace :image_sets do
  desc "Fetch ALL US transit stations from Wikidata (incl. defunct/closed). Local-only."
  task :fetch_us_transit, [ :user_email ] => :environment do |_, args|
    LocalUSTransit.fetch!(
      args: args,
      default_set_name: "US Transit Stations",
      active_only: false
    )
  end

  desc "Fetch only ACTIVE US transit stations (drops items with P576/P3999) from Wikidata. Local-only."
  task :fetch_us_transit_active, [ :user_email ] => :environment do |_, args|
    LocalUSTransit.fetch!(
      args: args,
      default_set_name: "US Transit Stations (active)",
      active_only: true
    )
  end
end
