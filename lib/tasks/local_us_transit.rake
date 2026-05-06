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
    Q22808404 station-located-on-surface
  ].each_slice(2).map(&:first).freeze
  # Q22808404's parent chain (station → public transport stop → ...)
  # doesn't pass through Q55488 — without listing it explicitly, items
  # with P31=Q22808404 and no other P31 (Montpellier on the Montreal
  # Metro Q3095526, many CTA/MBTA/DC Metro surface stops) are missed.

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

  # Reuse the seeder's filename heuristics for non-photo content.
  # Catches maps/schematics that shouldn't end up in the gallery —
  # Wikidata occasionally records a system map or schematic as a
  # station's P18 (e.g. Davidson Yard's P18 was "Union Pacific Railroad
  # system map.png").
  #
  # Patterns operate on the URL-DECODED filename. Earlier versions
  # matched against the raw URL where %20 is the space character, so
  # `_map[._]` only fired on filenames using underscores; filenames
  # like "Union Pacific Railroad system map (marked).png" snuck
  # through. Decoding once below normalizes both forms.
  NON_PHOTO_PATTERNS = [
    /\b(?:ASTER|MODIS|Landsat|Sentinel|MISR|Messtischblatt)\b/i,
    /\bmap\b\s*\.|\blocation[\s_-]map\b|\brelief[\s_-]map\b|\bsystem[\s_-]map\b|\b\d{4}[\s_-].*\bmap\b/i,
    /\b(?:topographic|schematic)\b|Harper.?s[\s_-]New/i
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

    # Wikipedia-image fallback: for items lacking wdt:P18 but with an
    # English Wikipedia article, batch-fetch the page's lead image via
    # MediaWiki's pageimages API. Mutates by_item in place to add the
    # image URL on each row that gets one.
    fetch_wikipedia_images!(by_item: by_item, label: label)

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
      # NON_PHOTO_PATTERNS need the decoded filename — see the comment
      # on the constant.
      decoded_filename = URI.decode_www_form_component(url.split("/").last.to_s)
      if NON_PHOTO_PATTERNS.any? { |p| decoded_filename.match?(p) }
        skipped_non_photo += 1
        next
      end

      title = b.dig("itemLabel", "value").presence || "Untitled"
      # Drop bare Q-ID labels (Wikibase falls back to the entity id when
      # no English label exists) — looks ugly in the UI.
      title = "Untitled" if title.match?(/\AQ\d+\z/)

      # Active-only: drop "Railroad Museum" / "Depot Museum" / "Trolley
      # Museum" type names — those are repurposed historic buildings,
      # not active stations (e.g. "National New York Central Railroad
      # Museum" Q6974578, "Batavia Depot Museum" Q4868668). Earlier
      # version of this used /\bmuseum\b/i which was way too broad —
      # it would drop Toronto's "Museum" TTC station (Q1041205) and
      # any other "Museum / X" stop. Tightened pattern only fires when
      # "museum" follows a clear non-station word.
      if active_only && title.match?(/\b(?:railroad|railway|train|depot|trolley|tram|transit|RR)\s+museum\b/i)
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

  # For every item with an English Wikipedia article, look up the
  # article's lead image (the PageImages-extension scored winner —
  # for station articles, reliably the infobox photo) and OVERWRITE
  # any wdt:P18 we already have. Wikidata P18 statements are often
  # years old: e.g. Church Street MBTA Q6410967's P18 was "Church
  # Street station near completion (1), December 2023.jpg" — a pre-
  # opening construction photo — while the Wikipedia infobox shows
  # "Inbound MBTA New Bedford Line train 2038 at Church Street March
  # 2025.jpg" — the actual operational station. Wikipedia infoboxes
  # get refreshed when stations are rebuilt or rephotographed; P18
  # rarely does.
  #
  # We use Action API piprop=name (just the filename) and construct a
  # Special:FilePath URL ourselves rather than piprop=thumbnail (which
  # forces a baked-in size that defeats our gallery's ?width=N query
  # param) or piprop=original (returns a 3840px-thumbnailed URL, big).
  # Special:FilePath serves the source file at full quality and the
  # display layer adds ?width=400 / ?width=800 as needed.
  #
  # WHY-NO-REDIRECTS: we don't pass redirects=1 to the API. If we did,
  # MediaWiki would silently follow station→town/line/list redirects
  # (e.g. Wikidata's "Whiteson railway station" sitelinks to a page
  # that redirects to "Whiteson, Oregon" — the town article — and
  # we'd import the town's lead photo as the station's image). Our
  # bug-bash on a 600-row sample found ~50 stations whose sitelinks
  # are now redirects; ~30 went to non-station targets (places, line
  # articles, lists). The cost of NOT following: ~15-20 stations per
  # 5000 silently get no image (and are dropped at the URL-blank
  # check), all of which are minor renames or alternate spellings.
  # That tradeoff is the right default; do not add redirects=1.
  WIKIPEDIA_API   = URI("https://en.wikipedia.org/w/api.php")
  WIKIPEDIA_BATCH = 50  # MediaWiki cap; one form-encoded POST per batch.
  COMMONS_FILEPATH = "https://commons.wikimedia.org/wiki/Special:FilePath/".freeze

  def fetch_wikipedia_images!(by_item:, label:)
    needs_wp = by_item.each_value.select { |b| b["article"] }
    if needs_wp.empty?
      puts "[#{label}] No items have a Wikipedia article to refresh from"
      return
    end

    title_to_row = {}
    needs_wp.each do |b|
      title = decode_wp_title(b["article"]["value"])
      title_to_row[title] = b
    end
    titles = title_to_row.keys

    total_batches = (titles.size.to_f / WIKIPEDIA_BATCH).ceil
    # Log progress at most ~10 times across the run regardless of batch
    # count — every Nth batch where N is total/10 (min 1). For a typical
    # ~100-batch fetch that's ~10 lines; small fetches log every batch.
    log_every = [ total_batches / 10, 1 ].max
    puts "[#{label}] Fetching Wikipedia infobox images for #{titles.size} item(s) (#{total_batches} batch(es), progress every #{log_every})..."
    $stdout.sync = true
    started   = Time.now
    refreshed = 0   # rows where Wikipedia gave us a (possibly different) image
    new_only  = 0   # rows that had no P18 and now do

    titles.each_slice(WIKIPEDIA_BATCH).each_with_index do |batch, idx|
      params = {
        action: "query",
        format: "json",
        prop:   "pageimages",
        piprop: "name",
        titles: batch.join("|")
      }
      req = Net::HTTP::Post.new(WIKIPEDIA_API)
      req["User-Agent"]   = USER_AGENT
      req["Accept"]       = "application/json"
      req["Content-Type"] = "application/x-www-form-urlencoded"
      req.body = URI.encode_www_form(params)

      response = nil
      begin
        response = Net::HTTP.start(WIKIPEDIA_API.hostname, WIKIPEDIA_API.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }
      rescue StandardError => e
        warn "[#{label}]   batch #{idx + 1}/#{total_batches}: network error #{e.class}: #{e.message}, skipping"
        next
      end

      unless response.code == "200"
        warn "[#{label}]   batch #{idx + 1}/#{total_batches}: HTTP #{response.code}, skipping"
        next
      end

      data       = JSON.parse(response.body)
      pages      = (data.dig("query", "pages") || {}).values
      normalized = (data.dig("query", "normalized") || []).each_with_object({}) { |n, h| h[n["from"]] = n["to"] }

      # Deliberately NO redirects=1 — see WHY-NO-REDIRECTS comment above.
      # Without it, MediaWiki returns redirect stub pages (which have no
      # pageimage and are silently skipped below). That's the right
      # default: a station whose en.wp article redirects to a town/line
      # article would otherwise have the town's lead photo imported.
      pages.each do |p|
        filename = p["pageimage"]
        next if filename.nil? || filename.empty?

        api_title = p["title"]
        original = title_to_row.keys.find { |t| t == api_title || normalized[t] == api_title }
        next unless original

        row = title_to_row[original]
        had_image = !row["image"].nil?
        row["image"] = { "value" => commons_filepath(filename) }
        refreshed += 1
        new_only  += 1 unless had_image
      end

      done_batches = idx + 1
      # Log first batch, every Nth batch, and the final batch — so the
      # user sees a startup line, periodic progress, and a clean finish.
      if done_batches == 1 || done_batches == total_batches || (done_batches % log_every).zero?
        elapsed = Time.now - started
        eta_s   = (total_batches - done_batches).zero? ? 0 : (elapsed / done_batches * (total_batches - done_batches))
        puts "[#{label}]   batch #{done_batches}/#{total_batches} — #{refreshed} images so far (~#{eta_s.round}s left)"
      end

      sleep 0.2 unless idx == total_batches - 1
    end

    failed = titles.size - refreshed
    puts "[#{label}] Wikipedia infobox: refreshed #{refreshed} image URL(s) in #{(Time.now - started).round(1)}s (#{new_only} previously had no P18; #{failed} pages had no pageimage — kept any P18)"
  end

  # Build a https://commons.wikimedia.org/wiki/Special:FilePath/<file> URL
  # from the bare pageimage filename Wikipedia returns. URI percent-
  # encoding via encode_www_form_component, then `+` → `%20` to land in
  # path-style encoding (Wikimedia accepts either, but %20 matches the
  # shape Wikidata P18 already gives us, which keeps the ?width=N
  # downsizing query param working consistently across the gallery).
  def commons_filepath(filename)
    encoded = URI.encode_www_form_component(filename).gsub("+", "%20")
    COMMONS_FILEPATH + encoded
  end

  # Convert https://en.wikipedia.org/wiki/McKnight%E2%80%93Westwinds_station
  # → "McKnight–Westwinds station" (percent-decoded, underscores → spaces).
  def decode_wp_title(article_url)
    encoded = article_url.split("/wiki/").last
    URI.decode_www_form_component(encoded).tr("_", " ")
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
    #
    # P576 (dissolved/demolished) and P3999 (date of official closure)
    # are only treated as exclusions when P5817 isn't currently "in
    # use". Reopened stations like Church Street MBTA (closed 1958,
    # reopened 2024 with South Coast Rail) keep the historical P3999
    # date but are flagged P5817 = "in use" — those should pass.
    minus_clause = active_only ? <<~MINUS : ""
      MINUS {
        ?item wdt:P576 ?dissolved .
        FILTER NOT EXISTS { ?item wdt:P5817 wd:Q55654238 }
      }
      MINUS {
        ?item wdt:P3999 ?closedAt .
        FILTER NOT EXISTS { ?item wdt:P5817 wd:Q55654238 }
      }
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
    # P18 (image) is OPTIONAL: items without one are kept if they have
    # an English Wikipedia article — fetch_wikipedia_images later pulls
    # the page's lead photo via the MediaWiki pageimages API. Catches
    # stations with sparse Wikidata data where the photo only lives in
    # the Wikipedia infobox (McKnight–Westwinds, MLK Jr station, Watt/
    # I-80, Strathearn stop, etc.).
    sparql = <<~SPARQL
      SELECT DISTINCT ?item ?itemLabel ?image ?coord ?article WHERE {
        VALUES ?country { #{countries} }
        ?item wdt:P31/wdt:P279* wd:#{type} ;
              wdt:P17 ?country ;
              wdt:P625 ?coord .
        OPTIONAL { ?item wdt:P18 ?image }
        OPTIONAL {
          ?article schema:about ?item ;
                   schema:isPartOf <https://en.wikipedia.org/> .
        }
        FILTER (BOUND(?image) || BOUND(?article))
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
