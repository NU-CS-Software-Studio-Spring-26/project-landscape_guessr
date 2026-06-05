require "net/http"
require "uri"
require "json"

# Turns a natural-language prompt ("volcanoes in Japan") into a Wikidata
# SPARQL graph pattern that the rest of the pipeline can run.
#
# Architecture: Gemini function-calling agent loop. The AI has two tools
# at its disposal:
#
#   search_wikidata(query)  — look up Q-IDs by label (wbsearchentities)
#   submit_answer(...)      — return the final structured payload
#
# The AI may call search_wikidata any number of times to resolve labels
# like "Frank Lloyd Wright" or "Buddhist temple" to Q-IDs, then calls
# submit_answer EXACTLY ONCE with the final SPARQL pattern. submit_answer
# replaces the response_schema we used to use; Gemini's API rejects
# response_schema + tools[] together (HTTP 400 INVALID_ARGUMENT), so we
# move structured-output enforcement into the tool's parameter schema.
#
# The only AI-controlled string that leaves the app is the SPARQL
# pattern, which is sent read-only to query.wikidata.org. Search queries
# are also AI-controlled but go to wbsearchentities (read-only).
#
# Cost: Flash with ~6 tool rounds per query = ~$0.02-0.05 per generation.
# At 50/month → ~$1-3. Pro (~$0.10-0.30 per generation) is used as a
# fallback only when Flash returns no usable answer.
class AiImageSetGenerator
  class Error < StandardError; end
  class RateLimitError < Error; end
  class InvalidResponseError < Error; end
  # A DETERMINISTIC rejection of the model's submit_answer payload (bad SPARQL,
  # missing required field). Unlike a transient InvalidResponseError (MALFORMED,
  # empty parts), re-running the same prompt won't help — so the pipeline must
  # NOT escalate it to Pro. We give the model one in-conversation chance to fix
  # it first (see the submit branch in #generate).
  class ValidationError < InvalidResponseError; end

  FLASH_MODEL = "gemini-2.5-flash".freeze
  PRO_MODEL   = "gemini-2.5-pro".freeze
  API_BASE    = "https://generativelanguage.googleapis.com/v1beta/models".freeze

  # Cap the function-call cycle. The AI typically resolves 2-4 Q-IDs per
  # query, plus the final submit_answer — so 10 turns is generous even with
  # the occasional MALFORMED / text-only / submit-rejection recovery round.
  # Going over means the AI is stuck in a loop; better to fail and let the
  # user refine.
  MAX_TOOL_ROUNDS = 10

  # Property list IS load-bearing — these are the SPARQL grammar, not
  # entity lookups. Search-tool results for property concepts are noisy
  # (search('country') #1 is "country music", not P17), so we hardcode
  # this short list. Everything else — categories, countries, people,
  # events, schema concepts — the AI discovers via search_wikidata.
  #
  # If the AI needs a property not in this list, it can search for it
  # with entity_type='property'. The search tool supports both.
  UNIVERSAL_PROPERTIES = <<~PROPS.freeze
      P31    instance of                   P279   subclass of
      P17    country                       P30    continent
      P36    capital (country->capital)    P1376  capital of (city->country)
      P18    image                         P625   coordinate location
      P131   located in admin entity       P84    architect
      P138   named after                   P361   part of
      P571   inception                     P576   dissolved/demolished
      P1435  heritage designation          P50    author
      P170   creator                       P175   performer
  PROPS

  # The two tools the AI has access to. search_wikidata fans out to the
  # wbsearchentities API; submit_answer is the AI's way of returning the
  # final structured payload (replaces response_schema since Gemini
  # rejects schema + tools together).
  TOOLS = [ {
    function_declarations: [
      {
        # Like submit_answer, the schema here is bare. Verbose descriptions
        # + enum constraints make Gemini Flash emit MALFORMED_FUNCTION_CALL
        # on multi-round prompts. Usage guidance lives in the system prompt.
        name: "search_wikidata",
        description: "Search Wikidata by English label. Returns up to 5 candidates. See system prompt for guidance.",
        parameters: {
          type: "OBJECT",
          properties: {
            query:       { type: "STRING" },
            # Renamed from `type` — that name reads as reserved to the
            # model (research/adk-go#492) and was a plausible contributor
            # to MALFORMED rate. `entity_type` is unambiguous.
            entity_type: { type: "STRING" }
          },
          required: [ "query" ]
        }
      },
      {
        name: "inspect_entity",
        description: "Inspect a known Wikidata item's actual claims (properties+values). Use to verify HOW Wikidata models a category — e.g. is 'UNESCO World Heritage Site' an instance (P31) or a designation (P1435) on member items? Pick a Q-ID you're confident is a representative example and inspect it.",
        parameters: {
          type: "OBJECT",
          properties: {
            qid: { type: "STRING" }
          },
          required: [ "qid" ]
        }
      },
      {
        # Batched OpenStreetMap Nominatim resolver. Used by the AI to
        # verify Mode B POI names resolve to the place it expects before
        # submitting (Nominatim's class/type metadata distinguishes a
        # park boundary from a random POI with the same name).
        name: "geocode",
        description: "Resolve 1-10 place names to coordinates via OpenStreetMap Nominatim. Returns top candidates per query with display_name, class/type, bbox, coords. Use to verify a sub-region name resolves to the place you mean before submitting (read display_name + class). Cache hits are instant; cold lookups rate-limited to ~1/sec.",
        parameters: {
          type: "OBJECT",
          properties: {
            queries: { type: "ARRAY", items: { type: "STRING" } }
          },
          required: [ "queries" ]
        }
      },
      {
        # Schema kept deliberately MINIMAL — earlier version with verbose
        # descriptions + `enum` constraint triggered Gemini Flash to emit
        # `finishReason: "MALFORMED_FUNCTION_CALL"` (empty parts) on ~40%
        # of prompts. Descriptions + constraints belong in the system
        # prompt; the function signature stays bare so Gemini reliably
        # produces well-formed calls. Server-side validation in
        # parse_submit catches bad values.
        name: "submit_answer",
        description: "Call exactly once with your final answer. Constraints on each field are in the system prompt.",
        parameters: {
          type: "OBJECT",
          properties: {
            image_source:             { type: "STRING" },  # wikidata | commons | mapillary
            sparql_pattern:           { type: "STRING" },  # wikidata only
            topic_qid:                { type: "STRING" },  # commons (for P373 lookup)
            combined_qid:             { type: "STRING" },  # commons (optional combined-concept Q-ID)
            commons_intitle_fallback: { type: "STRING" },  # commons (when no category): ONE singular title keyword, e.g. "skyline"
            mapillary_min_year:       { type: "STRING" },  # mapillary (optional)
            # Sub-region — exactly one BASE mode populated.
            # Mode A (in-DB)
            region_name:        { type: "STRING" },
            region_parent_name: { type: "STRING" },
            region_admin_level: { type: "STRING" },
            # Mode B (POI hull or single landmark)
            region_pois:        { type: "ARRAY", items: { type: "STRING" } },
            region_pois_label:  { type: "STRING" },
            # Optional radius transform (applies to whichever base is set)
            region_radius_meters: { type: "NUMBER" },

            set_name:           { type: "STRING" },
            explanation:        { type: "STRING" },
            cannot_answer:      { type: "BOOLEAN" }
          },
          required: %w[image_source set_name explanation cannot_answer]
        }
      }
    ]
  } ].freeze

  # `progress_callback` (optional): a callable that gets a human-readable
  # string ("Searching Wikidata for 'volcano'…") before each tool call
  # is dispatched. Used by AiGenerationPipeline to surface live progress
  # to the polling UI; tests + callers that don't care can omit it.
  def initialize(api_key: ENV["GEMINI_API_KEY"], model: :flash, timeout: 60, progress_callback: nil)
    raise Error, "GEMINI_API_KEY not configured" if api_key.blank?
    @api_key = api_key
    @model = model_id_for(model)
    @timeout = timeout
    @progress_callback = progress_callback
  end

  # `conversation` is an array of {role: "user"|"model", text: "..."} hashes
  # representing prior user/AI turns (the AI's prior turns are summarized
  # as the JSON they returned). The current user message must be the last
  # element with role: "user".
  #
  # Returns a parsed hash with keys :sparql_pattern, :set_name,
  # :explanation, :cannot_answer. Function-call loop is
  # internal; the returned hash is what submit_answer received.
  #
  # Logs per-round elapsed time + tool name on every round, plus a
  # summary line on completion. Grep `bin/dev` logs for `[ai_gen]` to
  # see the breakdown.
  def generate(conversation:)
    raise Error, "conversation must end with a user turn" unless conversation.last&.dig(:role) == "user"

    # Internal contents array uses Gemini's format. We rebuild it from
    # the simpler user-facing conversation, then append model+function
    # turns as the loop progresses.
    contents = conversation.map do |turn|
      { role: turn[:role], parts: [ { text: turn[:text] } ] }
    end

    text_only_retried = false
    submit_retried = false
    malformed_retries = 0
    started = Time.now
    gemini_time = 0.0
    tool_time = 0.0
    tool_counts = Hash.new(0)

    MAX_TOOL_ROUNDS.times do
      t0 = Time.now
      response = call_gemini(contents)
      gemini_time += Time.now - t0
      candidate = response.dig("candidates", 0) || {}
      parts = candidate.dig("content", "parts") || []
      if parts.empty?
        finish = candidate["finishReason"]
        # MALFORMED_FUNCTION_CALL is non-deterministic on Flash with
        # multi-round prompts — retry the SAME conversation up to 4 times
        # before giving up. The retry runs at temperature 0.2, so there's
        # some variance to shake it loose; Flash structured-output behavior
        # has stochastic edge cases.
        if finish == "MALFORMED_FUNCTION_CALL" && malformed_retries < 4
          malformed_retries += 1
          next
        end
        safety = candidate["safetyRatings"]
        usage = response["usageMetadata"]
        raise InvalidResponseError,
          "no parts in Gemini response (finishReason=#{finish.inspect}, " \
          "usage=#{usage.to_json}, safety=#{safety.to_json})"
      end

      function_calls = parts.select { |p| p["functionCall"] }

      if function_calls.empty?
        # AI emitted text without calling submit_answer. Gemini sometimes
        # forgets the tool-call instruction. Give it ONE chance to recover
        # by re-prompting explicitly. If it still skips submit_answer
        # after that, fail loud.
        if text_only_retried
          text = parts.find { |p| p["text"] }&.dig("text").to_s.slice(0, 300)
          raise InvalidResponseError, "AI emitted text instead of calling submit_answer (after retry): #{text.inspect}"
        end
        contents << { role: "model", parts: parts }
        contents << {
          role: "user",
          parts: [ { text: "You must respond by calling the submit_answer function, not by writing text. Call submit_answer now with your final answer." } ]
        }
        text_only_retried = true
        next
      end

      # Append the AI's model turn (the function calls). Required by
      # Gemini's protocol — the next request must include the model's
      # functionCall AND our functionResponse, in order.
      contents << { role: "model", parts: parts }

      submit = function_calls.find { |fc| fc.dig("functionCall", "name") == "submit_answer" }
      if submit
        tool_counts["submit_answer"] += 1
        begin
          payload = parse_submit(submit["functionCall"]["args"])
          log_generate_summary(started, gemini_time, tool_time, tool_counts)
          return payload
        rescue ValidationError => e
          # The payload was DETERMINISTICALLY rejected (bad SPARQL, missing
          # field). Re-running the whole prompt on Pro would likely repeat the
          # same mistake, so instead feed the exact error back and let the model
          # self-correct ONCE in-conversation — Flash reliably fixes e.g. a
          # stray sub-SELECT when told precisely what was wrong. Still failing
          # after that re-raises (a real ValidationError the pipeline surfaces).
          raise if submit_retried
          submit_retried = true
          report_progress("Adjusting the query…")
          contents << {
            role: "user",
            parts: function_calls.map { |fc|
              fname = fc.dig("functionCall", "name")
              content = fname == "submit_answer" ? { error: e.message } : run_tool(fname, fc.dig("functionCall", "args") || {})
              { functionResponse: { name: fname, response: { content: content } } }
            } + [ { text: "submit_answer was rejected: #{e.message}. Fix exactly that and call submit_answer again. Reminder: sparql_pattern is ONLY a WHERE-clause body — no SELECT/sub-SELECT, LIMIT, or SERVICE; subnational regions use region_admin_level, not wdt:P17." } ]
          }
          next
        end
      end

      # All search_wikidata responses go in ONE user turn with multiple
      # parts. Earlier draft put each response in its own turn — Gemini's
      # protocol for parallel function calls expects them batched.
      t_tools = Time.now
      response_parts = function_calls.map do |fc|
        name = fc.dig("functionCall", "name")
        args = fc.dig("functionCall", "args") || {}
        tool_counts[name] += 1
        report_progress(describe_tool_call(name, args))
        result = run_tool(name, args)
        { functionResponse: { name: name, response: { content: result } } }
      end
      tool_time += Time.now - t_tools
      contents << { role: "user", parts: response_parts }
    end

    log_generate_summary(started, gemini_time, tool_time, tool_counts)
    raise InvalidResponseError, "Hit MAX_TOOL_ROUNDS (#{MAX_TOOL_ROUNDS}) without submit_answer — AI is stuck"
  end

  def log_generate_summary(started, gemini_time, tool_time, tool_counts)
    elapsed = (Time.now - started).round(2)
    counts = tool_counts.map { |k, v| "#{k}=#{v}" }.join(" ")
    Rails.logger.info "[ai_gen] gemini=#{gemini_time.round(2)}s tools=#{tool_time.round(2)}s total=#{elapsed}s (#{counts})" if defined?(Rails)
  end

  private

  def model_id_for(model)
    case model.to_sym
    when :flash then FLASH_MODEL
    when :pro   then PRO_MODEL
    else raise Error, "unknown model: #{model.inspect}"
    end
  end

  def call_gemini(contents)
    body = {
      systemInstruction: { parts: [ { text: system_prompt } ] },
      contents: contents,
      tools: TOOLS,
      # VALIDATED mode is Google's documented fix for MALFORMED_FUNCTION_CALL:
      # the model is constrained to either call one of the allowed functions
      # OR emit text — and the output is schema-validated before being
      # returned. AUTO (the default) lets the model freestyle structure,
      # which is what produces empty parts + MALFORMED on multi-round
      # prompts. See https://ai.google.dev/gemini-api/docs/function-calling.
      toolConfig: {
        functionCallingConfig: {
          mode: "VALIDATED",
          allowedFunctionNames: %w[search_wikidata inspect_entity geocode submit_answer]
        }
      },
      generationConfig: {
        # Thinking gives the model space to plan tool calls cleanly.
        # 0 reliably worsens MALFORMED rate; 500-1500 are similar
        # quality. 1000 is the conservative middle — modest latency
        # savings vs 1500 with no measured quality hit. Don't drop
        # below ~500 without re-running the eval. CRITICAL companion:
        # thoughtSignature parts on returned functionCall parts MUST
        # be echoed back verbatim in the next turn — Ruby's Hash
        # preserves unknown keys when we round-trip via JSON.parse /
        # JSON.generate, so the existing `contents << { role: "model",
        # parts: parts }` already does this. Don't strip fields from
        # response parts.
        thinkingConfig: { thinkingBudget: 1000 },
        maxOutputTokens: 4096,
        temperature: 0.2
      }
    }

    JSON.parse(post_with_retry(body).body)
  end

  def post_with_retry(body)
    uri = URI("#{API_BASE}/#{@model}:generateContent")
    attempts = 0
    max_attempts = 2

    loop do
      attempts += 1
      req = Net::HTTP::Post.new(uri)
      req["Content-Type"] = "application/json"
      req["x-goog-api-key"] = @api_key
      req.body = JSON.generate(body)

      begin
        response = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: @timeout) do |h|
          h.request(req)
        end
      rescue Net::ReadTimeout, Net::OpenTimeout, EOFError, Errno::ECONNRESET => e
        # Connection-level failures are retryable just like 5xx. Without
        # this, a Gemini read-timeout (Pro warm-start can be slow) bubbles
        # raw Net::ReadTimeout past the pipeline's `rescue Error` clauses
        # and falsely marks the whole generation as failed. Wrap in our
        # own Error class on the last attempt so callers' rescue clauses
        # actually catch it.
        if attempts < max_attempts
          Rails.logger.warn "[ai_gen] #{e.class} on attempt #{attempts}, retrying…" if defined?(Rails)
          sleep 2 * attempts
          next
        end
        raise Error, "Gemini API connection timed out (#{e.class}: #{e.message})"
      end

      return response if response.code == "200"

      retryable = response.code == "429" || response.code.start_with?("5")
      if retryable && attempts < max_attempts
        sleep 2 * attempts
        next
      end

      raise RateLimitError, "Gemini rate-limited (#{response.code})" if response.code == "429"
      raise Error, "Gemini API #{response.code}: #{response.body.to_s[0, 300]}"
    end
  end

  # Best-effort progress notification. Swallow errors — the callback
  # is purely informational; an exception writing a status field should
  # never break the AI run.
  def report_progress(message)
    @progress_callback&.call(message)
  rescue StandardError => e
    Rails.logger.warn "[ai_gen progress] #{e.class}: #{e.message}" if defined?(Rails)
  end

  def describe_tool_call(name, args)
    case name
    when "search_wikidata"
      q = args["query"].to_s.strip
      q.empty? ? "Searching Wikidata…" : "Searching Wikidata for \"#{q.slice(0, 60)}\"…"
    when "inspect_entity"
      qid = args["qid"].to_s
      qid.empty? ? "Inspecting a Wikidata entity…" : "Inspecting #{qid}…"
    when "geocode"
      queries = Array(args["queries"]).first(3).join(", ")
      queries.empty? ? "Geocoding…" : "Geocoding \"#{queries.slice(0, 80)}\"…"
    when "submit_answer"
      "Composing the final query…"
    else
      "Thinking…"
    end
  end

  # Dispatch a function call to the right service. Returns a JSON-
  # serializable hash that Gemini will read back as the function's
  # response.
  def run_tool(name, args)
    case name
    when "search_wikidata"
      type = %w[item property].include?(args["entity_type"]) ? args["entity_type"] : "item"
      hits = WikidataEntitySearch.search(query: args["query"].to_s, type: type)
      { results: hits }
    when "inspect_entity"
      entity = WikidataEntityInspect.inspect_entity(qid: args["qid"].to_s)
      entity ? { entity: entity } : { error: "no entity found for #{args["qid"]}" }
    when "geocode"
      queries = Array(args["queries"]).first(10).map(&:to_s).reject(&:blank?)
      results = GeocoderService.geocode_many(queries: queries)
      # Trim the candidate hashes to the minimum the AI needs (cuts down
      # context bloat from full display_name + addressdetails on every
      # candidate).
      slim = results.transform_values do |list|
        list.first(5).map do |c|
          {
            display_name: c[:display_name],
            class: c[:class], type: c[:type],
            lat: c[:lat].round(5), lng: c[:lng].round(5),
            area_km2: c[:area_km2].round(2),
            importance: c[:importance].round(3)
          }
        end
      end
      { results: slim }
    else
      { error: "unknown function: #{name}" }
    end
  end

  # Validate + return the submit_answer payload. Defensive checks even
  # though Gemini's parameter schema should enforce required fields;
  # the AI occasionally violates schemas in practice.
  ALLOWED_SOURCES = %w[wikidata commons mapillary].freeze

  def parse_submit(args)
    source = args["image_source"].to_s.strip.downcase
    source = "wikidata" unless ALLOWED_SOURCES.include?(source)

    payload = {
      image_source:             source,
      sparql_pattern:           args["sparql_pattern"].to_s,
      topic_qid:                args["topic_qid"].to_s.strip.presence,
      combined_qid:             args["combined_qid"].to_s.strip.presence,
      commons_intitle_fallback: args["commons_intitle_fallback"].to_s.strip.presence,
      mapillary_min_year:       args["mapillary_min_year"].to_s.strip.presence,
      set_name:                 args["set_name"].to_s.strip.presence || "Untitled AI Set",
      explanation:              args["explanation"].to_s.strip,
      cannot_answer:            args["cannot_answer"] == true,
      region:                   build_region_descriptor(args)
    }

    return payload if payload[:cannot_answer]

    case source
    when "wikidata"
      raise ValidationError, "wikidata source requires sparql_pattern" if payload[:sparql_pattern].strip.empty?
      validate_sparql!(payload[:sparql_pattern])
    when "commons"
      unless payload[:topic_qid] || payload[:combined_qid] || payload[:commons_intitle_fallback]
        raise ValidationError, "commons source requires topic_qid, combined_qid, or commons_intitle_fallback"
      end
    when "mapillary"
      raise ValidationError, "mapillary source requires a region (Mode A or B)" if payload[:region].nil?
    end

    payload
  end

  # Block any keyword that either breaks our outer wrapping or could
  # let the AI take the query somewhere we don't control.
  FORBIDDEN_SPARQL_KEYWORDS = %w[SELECT LIMIT SERVICE DESCRIBE ASK CONSTRUCT INSERT DELETE LOAD CLEAR DROP WITH].freeze

  def validate_sparql!(pattern)
    FORBIDDEN_SPARQL_KEYWORDS.each do |kw|
      raise ValidationError, "AI returned #{kw} in sparql_pattern (not allowed)" if pattern =~ /\b#{kw}\b/i
    end
  end

  ALLOWED_ADMIN_LEVELS = %w[world continent country admin1 admin2 city].freeze

  # Mode A: region_name + region_admin_level set.
  # Mode B: region_pois (array) set.
  # Optional radius (positive number, max 50_000m) applied to either.
  # Returns nil if neither mode populated.
  def build_region_descriptor(args)
    name  = args["region_name"].to_s.strip.presence
    level = args["region_admin_level"].to_s.strip.presence
    parent_name = args["region_parent_name"].to_s.strip.presence
    pois = Array(args["region_pois"]).map(&:to_s).map(&:strip).reject(&:blank?)
    radius_raw = args["region_radius_meters"]
    radius = (radius_raw.is_a?(Numeric) || radius_raw.to_s =~ /\A\d+(\.\d+)?\z/) ? radius_raw.to_f : nil
    radius = nil if radius && (radius <= 0 || radius > 50_000)

    base =
      if name && ALLOWED_ADMIN_LEVELS.include?(level)
        { mode: "named", name: name, parent_name: parent_name, admin_level: level }
      elsif pois.any?
        { mode: "pois", pois: pois.first(10), label: args["region_pois_label"].to_s.strip.presence }
      end
    return nil unless base
    radius ? base.merge(radius_meters: radius) : base
  end

  def system_prompt
    <<~PROMPT
      You generate image-set queries from natural-language prompts.
      Three sources are available — pick the right one, then resolve
      Q-IDs / region names via tools, then call submit_answer.

      SOURCES (set `image_source` in submit_answer):
      - "wikidata"  — default for topic+region prompts ("churches in Paris",
                      "lakes in Massachusetts"). High-quality curated items
                      with one canonical photo each.
      - "commons"   — many photos of one subject ("Mount Fuji photos") OR
                      sparse Wikidata topics (street art, graffiti, murals)
                      OR explicit "many photos / lots of photos in X".
      - "mapillary" — street-level imagery for road/street prompts
                      ("streets in Chicago", "driving through Sweden",
                      "street view in Shibuya").

      ROUTING DECISIONS (consult before any tool call):
      - "streets / roads / driving in X" → mapillary
      - "streets around the world", "anywhere in the world", "random
        streets", "drive anywhere" (no place named) → mapillary with
        region_admin_level: "world" (region_name: "World"). This is the
        classic guessing mode — DO NOT refuse it; the backend samples
        street imagery distributed across the globe.
      - "X in Y" topic+region (typical case) → wikidata
      - "many photos / lots of photos of X" → commons
      - Single subject, many angles ("Mount Fuji photos") → commons
      - Subjects Wikidata models as a generic CLASS instead of discrete
        geotagged items → commons. This covers land-cover & agriculture
        (rice terraces, vineyards, fields, hedgerows, moorland, pastures,
        orchards) and sparse cultural topics (street art, graffiti, murals):
        a wdt:P31/P279* walk on these returns a handful of items or zero.
      - Living things (wildlife, animals, birds, fish, plants, trees) →
        commons. Wikidata has SPECIES/taxa, which carry no coordinates, so a
        Wikidata query returns 0; Commons has geotagged photos of them.
      - Multi-region prompts ("NYC and LA", "50 cities") → cannot_answer
      - Named routes ("Highway 101", "I-90") → cannot_answer
      - Directional splits ("north half of Chicago") → cannot_answer
        (suggest filter-by-area after importing the broader region)

      UNIVERSAL PROPERTIES (no need to search for these):
      #{UNIVERSAL_PROPERTIES}

      REFINEMENT TURNS:
      If the conversation has prior turns, the user is refining a
      previous answer of yours. PRESERVE every constraint from earlier
      turns unless the user explicitly removes one. Constraints
      include: region/country filters, class/category filters, time-
      period filters, count caps, attribute thresholds. Silently
      dropping a constraint is a failure mode — if you can't tell
      whether the user meant to drop a constraint, keep it.

      Example: turn 1 = "volcanoes in Japan" → you generated wd:Q8072
      + wd:Q17. Turn 2 = "include extinct ones too" → keep Japan AND
      the volcano class, add the extinct-volcano alternative. Do NOT
      regenerate as "volcanoes worldwide".

      WORKFLOW:
      1. Identify the entities and relationships in the user's request.
      2. For each one, call search_wikidata with a SHORT English label
         (e.g. "volcano", "Japan", "Frank Lloyd Wright" — not the user's
         whole sentence). For properties not in the universal list above,
         set entity_type="property".
      3. Read every candidate's DESCRIPTION and pick the one whose
         description matches your intent. The ranking is label-match,
         not semantic — for common nouns the #1 result is often wrong
         (e.g. search('country') returns "country music" first). If no
         candidate clearly fits, search again with a different phrasing.
      4. If you're uncertain HOW Wikidata models the category (e.g. is
         "Gothic" a P31 class on its own, or a P149 value on a building
         that's classed as P31 wd:Q41176? is "UNESCO World Heritage Site"
         used as P31 or P1435?), pick a Q-ID you know is a representative
         example (e.g. search "Notre-Dame de Paris" → inspect that
         entity) and call inspect_entity. The claims you see will show
         which property carries the attribute you care about.
      5. Compose the SPARQL pattern using only the Q-IDs you've
         verified through search/inspect.
      6. Call submit_answer.

      SUBMIT_ANSWER FIELD CONSTRAINTS:
      - sparql_pattern: SPARQL WHERE-clause body. MUST bind ?item and
        ?coord. The matched-item variable MUST be exactly ?item (not
        ?place, ?building, etc.) — the backend rewrites the type triple
        and assumes that name. MUST NOT contain SELECT (not even a
        sub-SELECT), LIMIT, or SERVICE blocks — the server adds those,
        plus its own
        OPTIONAL+FILTER trailer for the image/article fallback. Empty
        string is OK when cannot_answer=true. Basic shape:
        `?item wdt:P31/wdt:P279* wd:Q##### ; wdt:P17 wd:Q## ; wdt:P625 ?coord .`
        Use wdt:P31/wdt:P279* (subclass walk) for broad categories;
        exact wdt:P31 for narrow concepts with deliberate scope.

        You ARE allowed (and encouraged for the relevant cases) to use:
          * FILTER for numeric thresholds, date ranges, regex.
            Examples:
              ?item wdt:P2043 ?length . FILTER(?length > 500)
              ?item wdt:P571 ?built . FILTER(YEAR(?built) >= 1900)
          * OPTIONAL for attributes that may or may not be present and
            shouldn't drop the row if absent.
          * UNION for "either X or Y" alternatives that aren't easily
            expressed as VALUES.

      - When the user asks for something subjective ("major", "famous",
        "notable") AND there's a measurable proxy (length, height,
        population, year built), pick a SENSIBLE THRESHOLD and use it.
        Don't refuse just because the line is fuzzy. Mention the
        threshold you chose in `explanation` so the user can adjust it
        in a refinement turn. Example: "I picked mountain ranges with
        a recorded length > 500 km. Want a different cutoff?"
      - set_name: 4-6 words, Title Case ("Volcanoes of Japan").
      - explanation: 1-2 plain-English sentences, no jargon.
      - cannot_answer: boolean. true to refuse, false to provide a pattern.
      - region_name, region_parent_name, region_admin_level: optional
        sub-national region filter. See REGION FILTERS below. When set,
        sparql_pattern MUST omit geo constraints (no wdt:P131*, no
        wdt:P17 for the same region).

      MODELING PRINCIPLES (apply these before composing the pattern):

      - **The match must be geotaggable (check FIRST).** The Wikidata source
        returns one photo per matched ?item, anchored on that item's own
        P625 coordinate — so the kind of thing you P31-match MUST be
        something that HAS a fixed location: places, buildings, structures,
        monuments, natural features (mountains, lakes, rivers), located
        events. Taxa/species (animals, birds, fish, plants, trees), people,
        artworks-as-concepts, vehicles, and organizations have NO P625 and
        return ZERO rows — even though the class Q-ID exists and looks valid.
        For those subjects switch to image_source="commons" (geotagged
        PHOTOS of them exist) or, if Commons coverage is doubtful, refuse.
        Never emit a Wikidata pattern whose ?item is a taxon/person/vehicle.

      - **A named large AREA is a REGION, not a subject.** A mountain range,
        desert, plateau, basin, or natural region used as the subject ("the
        Alps", "the Swiss Alps", "the Sahara", "the Rockies", "the Outback",
        "the Amazon") is NOT a single point and NOT a Wikidata class — a
        P31/P279* walk on its Q-ID returns ~0, and a bare commons topic_qid
        with no region collapses the whole import to a 30km circle at the
        area's centroid. Instead treat the AREA as the region: set
        region_pois to its name (geocode returns its real bbox), or use a
        Mode A admin region when the user scoped it to one ("the swiss alps"
        → region_name "Switzerland"), and pair it with image_source="commons"
        using the area's own Commons category (topic_qid). The category
        keeps it on-topic; the region spreads it across the whole area.

      - **Designations & statuses (use a UNION, don't guess the property).**
        Designations like World Heritage Site, listed/heritage building,
        national monument, protected-area status are modeled INCONSISTENTLY
        on Wikidata: some items are P31 the designation-class, others carry
        it via wdt:P1435 (heritage designation). Catching only one misses
        the rest. Cover both with a UNION instead of inspecting:
          { ?item wdt:P31/wdt:P279* wd:Q9259 } UNION { ?item wdt:P1435 wd:Q9259 }
          ?item wdt:P625 ?coord .
        (Q9259 = World Heritage Site; substitute the designation's Q-ID.)

      - **Attribute, not class.** When the user describes things with an
        ATTRIBUTE (style, designation, status, award, role, period),
        the attribute almost always has its own dedicated PROPERTY.
        Examples of attribute kinds — architectural style, art movement,
        heritage designation, listing status, awards, era, denomination.
        Find the property that models that attribute (search with
        entity_type="property"); do NOT filter on wdt:P31 of the
        attribute's name. The item's P31 should be the "kind of thing"
        (e.g. "building", "city"), and the attribute lives in a separate
        triple.

      - **Relation, not class.** "X of Y" relations (capital of, work by,
        member of) use a property, not P31. Look for the property that
        directly links X to Y. For "all capitals of countries":
        `?country wdt:P36 ?item`, not `?item wdt:P31 wd:Q5119`.

      - **Exclude nuisance subclasses with MINUS.** A broad
        wdt:P31/wdt:P279* walk can drag in a high-volume subclass the user
        doesn't mean, which then dominates the random sample. The canonical
        case is "churches" (wd:Q16970): Wikidata models cemetery tomb-chapels
        as "sepulchral chapel" (wd:Q1424583, a subclass of church building)
        and individual "grave" (wd:Q173387) items, which in dense old cities
        can outnumber real churches — so a plain Q16970 walk returns mostly
        items labelled "Grave of …". Exclude them:
          ?item wdt:P31/wdt:P279* wd:Q16970 ; wdt:P625 ?coord .
          MINUS { ?item wdt:P31/wdt:P279* wd:Q1424583 }   # sepulchral chapels (graves)
          MINUS { ?item wdt:P31 wd:Q173387 }              # graves
        MINUS is allowed. Apply the same idea whenever a category has an
        obvious funerary/edge subclass (tombs, mausoleums) you don't want;
        note the exclusion in `explanation`. If a refinement turn says the
        results are "graves" / "tombs" / wrong sub-type, ADD the MINUS.

      - **Sovereign filtering.** If "country" must mean an actual
        sovereign nation (not territory/region), search for the
        sovereign-state concept Q-ID and constrain with that.

      - **Continents** (Africa, Antarctica, Asia, Europe, North America,
        Oceania, South America): use the region_filter fields with
        `region_admin_level: "continent"` — the backend has bboxes +
        polygons seeded for all seven. Do NOT enumerate every country
        with VALUES, and do NOT compose any geo constraint in the
        sparql_pattern.

      - **Other multi-country groupings** ("Scandinavia", "the Maghreb",
        "DACH") aren't continents and aren't in our region table —
        enumerate explicitly: `VALUES ?country { wd:QA wd:QB ... } .
        ?item wdt:P17 ?country` — search each country Q-ID first.

      - **Umbrella concepts that span multiple classes.** Applies ONLY
        when the user's request is a vibe / domain / feeling and no
        single Wikidata class captures it. Examples that ARE umbrellas:
        "nature", "architecture", "infrastructure". Examples that are NOT
        umbrellas (these are specific classes — use a single type, do not
        enumerate): "rivers worldwide", "volcanoes worldwide", "skyscrapers
        in Asia", "lighthouses worldwide". Broad scope ≠ umbrella; only
        enumerate when no single class fits. Whatever sub-types you pick,
        each MUST be geotaggable (see the first principle) — decompose
        "transportation" into bridges/stations/airports/ports (placed
        infrastructure), never into "car/train/plane" (vehicles, no P625);
        "wildlife" has no geotaggable decomposition at all → use Commons.

        For umbrellas: ENUMERATE EXHAUSTIVELY by sub-domain. Think of
        the umbrella like a Wikipedia category page — what *kinds* of
        things belong? Group your brainstorm so you don't miss whole
        branches. For "natural scenery", the sub-domains are landforms
        (mountain, plateau, valley, cliff...), water (lake, river,
        waterfall...), shore (beach, coast, fjord, island...), thermal
        (volcano, geyser...), vegetated (forest, wetland...), arid
        (desert, dune...). Apply the same sub-domain decomposition to
        any umbrella the user gives you.

        Target: 15-25 candidate types brainstormed, search them ALL
        in one turn (emit many search_wikidata calls in parallel),
        keep those with confident Q-IDs (typically 12-20 final).
        Each search is ~0.2s; missing a category means missing a
        whole class of images, so thoroughness is cheap.

        Final shape for umbrellas:
          VALUES ?type { wd:QA wd:QB ... wd:QT }
          ?item wdt:P31/wdt:P279* ?type ; wdt:P625 ?coord .

        Final shape for specific classes (even broad-worldwide ones):
          ?item wdt:P31/wdt:P279* wd:Q##### ; wdt:P625 ?coord .

      REFUSAL — call submit_answer with cannot_answer=true if:
      - The category isn't comprehensively indexed in Wikidata — even if
        a Q-ID exists for the concept itself. Restaurants/shops/cafes
        are the canonical case: there IS a Q-ID for "ramen shop"
        (Q23812032), but Wikidata indexes only a handful of notable
        examples, not the millions in real cities. Same logic for:
        small private buildings, individual residences, local
        businesses, social media accounts, recent events, people below
        encyclopedic-celebrity threshold.
      - The request is about ONE specific named subject — "photos of
        the Eiffel Tower", "Mt. Fuji from different angles", "the
        Statue of Liberty". Our pipeline returns ONE photo per matched
        Wikidata item, so a single-subject request only yields 1
        image. Refuse and suggest a category alternative ("photos of
        famous towers worldwide?").

        Do NOT misapply this to "category in region" requests, which
        DO fit fine — they fan out across many items. Examples that
        should NOT trigger this refusal: "nature in Massachusetts"
        (lakes, mountains, parks — many items), "buildings by Frank
        Lloyd Wright" (many items, each a building), "lighthouses
        worldwide" (many items), "street scenes in Tokyo" if
        interpreted as famous-streets-in-Tokyo (each is its own item).
      - The user's request is too vague to model ("stuff", "things",
        "some images").
      - Search results don't give you a confident Q-ID for the
        CATEGORY (i.e. the kind of thing you'd P31-match) after 2-3
        rephrasings. Don't guess.

      WHAT THE BACKEND DOES FOR YOU:

      - Per-type fan-out: each Q-ID in `VALUES ?type { ... }` runs as
        its OWN parallel query against WDQS. A 14-type umbrella isn't
        one giant query — it's 14 narrow queries that each get the full
        WDQS 60-second budget.
      - Random sampling: every fetch is randomized via ORDER BY a
        hashed RAND() inside a subquery. If a type has more than
        10,000 matching items, the backend returns a true random
        sample of 10,000 (not the alphabetical-first-10,000 that a
        plain LIMIT would give). You don't choose a "strategy" — the
        backend always samples randomly.
      - Region bbox: when region_name is set, the backend looks up the
        region's bounding box from our Region table (continent, admin1,
        admin2, or city) and prepends SERVICE wikibase:box to your
        pattern, then drops rows outside the region's actual polygon.
        You MUST NOT compose wdt:P131*, wdt:P30, or any other geo
        constraint when region_name is set.
      - Cap warning: if a type exceeds the 10k cap, the show page
        shows the user a "this category had more than 10,000 items —
        sample shown" hint. You don't need to engineer around the cap.

      PERFORMANCE — Selective numeric filters without geography:

      For "X with property > threshold worldwide" (no country anchor),
      the standard P31/P279* pattern times out because WDQS walks the
      whole subclass tree before applying the FILTER.

      When the FILTER is SELECTIVE (narrows to <20k items globally —
      e.g. height > 200m, length > 500km, population > 10M, founded
      before 1500), drop the P31 constraint entirely:

        ?item wdt:P2048 ?height ; wdt:P625 ?coord . FILTER(?height > 200)

      instead of:

        ?item wdt:P31/wdt:P279* wd:Q41176 ; wdt:P2048 ?height ;
              wdt:P625 ?coord . FILTER(?height > 200)

      WDQS starts from the (small) set of items with the property,
      filters, then joins — instead of walking millions of buildings.

      Trade-off: returns ANY item with that property, not just the
      target class. Acknowledge in your explanation, e.g.:
        "Note: includes non-target items that share this property
        (mountains have heights too)."

      Apply ONLY for selective thresholds. For mild ones (height >
      50m, population > 100k), the property alone matches too many
      items — keep P31.

      REGION SPEC — TWO BASE MODES + OPTIONAL RADIUS:

      Pick exactly ONE base mode. Add radius_meters only when the
      user's prompt specifies one (or implies one — "near X" without
      a number defaults to ~2000m).

      ---- MODE A (in-DB named region) ----
      Use when the user names a place that's a city / admin1 / admin2 /
      country / continent already in our region table.
      Fields:
        region_name        — canonical English name. "United States" not
                             "USA"; "Munich" not "München" (geonames is English).
        region_admin_level — exactly one of: "world" (whole globe — for
                             "streets around the world" / "anywhere"),
                             "continent", "country", "admin1"
                             (state/province), "admin2" (county), "city".
        region_parent_name — parent's English name. For admin1, the
                             country ("United States"). For city, the
                             admin1 or admin2 ("Illinois" for Chicago).
                             Omit for continents and most countries.

      For ALL Mode A regions including continents, the backend handles
      the geometry — your wikidata sparql_pattern must NOT include any
      geo constraint (no wdt:P131*, no wdt:P17 for the same place, no
      bbox FILTERs). Just class + coord:
        ?item wdt:P31/wdt:P279* wd:Q23397 ; wdt:P625 ?coord .

      Country-level note: for wikidata source you MAY use wdt:P17 wd:Q##
      directly in the SPARQL instead of region_admin_level="country" — but
      ONLY for a SOVEREIGN state (a UN member: France Q142, Japan Q17, USA
      Q30). P17 is the *sovereign country*, so a CONSTITUENT country or any
      subnational area — Scotland (Q22), Wales, England, Northern Ireland,
      Bavaria, California, Catalonia, Québec — has P17 = its sovereign parent
      (a castle in Scotland is P17 United Kingdom, NOT P17 Scotland), so
      `wdt:P17 wd:Q22` matches ZERO items. For ANYTHING subnational, set
      region_admin_level="admin1" (no geo triple in the SPARQL) and let the
      backend's bbox + polygon filter it. P17 is slightly faster only for
      whole sovereign countries with odd bbox shapes (Russia, USA).

      ---- MODE B (POI hull / single landmark) ----
      Use when:
        * A sub-city named place that's NOT in our DB ("Shibuya",
          "Lincoln Park, Chicago", "Mission District", "Marais")
        * A single landmark used as a radius anchor ("Eiffel Tower",
          "Times Square", "Yellowstone")
        * A compound region defined by named places spread across the
          area ("Bay Area" = SF + Oakland + San Jose + Palo Alto;
          "downtown Tokyo" = Marunouchi + Ginza + Chiyoda)
      Fields:
        region_pois        — array of 1-10 place names, each precise
                             enough that OpenStreetMap Nominatim resolves
                             it. Disambiguate with parent ("Lincoln Park,
                             Chicago" not just "Lincoln Park"; "Cambridge,
                             Massachusetts" not just "Cambridge").
        region_pois_label  — short human label for the combined region
                             ("Bay Area", "downtown Tokyo").

      Call geocode(queries=[...]) FIRST to verify each POI resolves to
      the right place. Read display_name + class — prefer boundary or
      place results over railway/amenity. If a query returns nothing
      useful, rephrase ("Brooklyn" → "Brooklyn, New York").

      ---- OPTIONAL RADIUS ----
      region_radius_meters — applies to whichever base is set. Centers a
                             square of that radius on the resolved base
                             centroid (overrides the base's natural bbox).
      Use for "near X", "around Y", "within Nkm/miles of Z" prompts.
      Convert miles to meters (1 mile ≈ 1609m). Cap is 50000m (50km).
      Examples:
        "near the Eiffel Tower"          → radius_meters: 2000
        "5km around downtown LA"         → radius_meters: 5000
        "10 miles from Yellowstone"      → radius_meters: 16093
        "within 1 mile of Times Square"  → radius_meters: 1609

      When BOTH base modes are blank and no radius is set, the prompt
      has no region constraint (rare — most wikidata prompts have one;
      most commons "subject" prompts don't; mapillary REQUIRES a region).

      REFUSE these region shapes with cannot_answer:
      - Directional splits ("north half of Chicago", "east side of Berlin")
        → suggest filter-by-area after importing the broader region.
      - Freeform corridors ("from A to B", "strip between X and Y")
        → suggest filter-by-area.
      - Multi-region ("X and Y", "all states in the US") → suggest
        importing one region and using filter-by-area, OR the broader
        continent/country.

      EXPLANATION STYLE:
      - Plain English, friendly, no jargon.
      - Bad: "Filters wd:Q8072 via wdt:P31/wdt:P279* with wdt:P17 wd:Q17."
      - Good: "I'll find volcanoes located in Japan that have photos."
      - If your query doesn't fully cover the user's request, name the
        part you couldn't honor and offer to adjust. Don't silently
        drop pieces of their ask.
      - For multi-country/multi-region groupings whose definition
        could vary ("Scandinavia", "Latin America", "Middle East",
        "British Isles"), list the countries you picked so the user
        can spot a wrong interpretation. Well-known fixed groupings
        (Benelux, DACH, EU, NATO) don't need the enumeration —
        naming the grouping is enough.
      - When cannot_answer=true, suggest the nearest workable
        alternative if one exists. Avoid bare "I can't" dead-ends.

      COMMONS SOURCE (image_source: "commons"):

      Use Wikimedia Commons CirrusSearch with a category bridge from
      Wikidata's P373 property. The backend bridges your topic Q-ID to a
      Commons category, then queries with deepcategory: + nearcoord:.

      Provide:
        topic_qid               — Q-ID for the SUBJECT (not the place).
                                  Backend looks up its P373 Commons
                                  category. "Mount Fuji photos" → Mt Fuji
                                  Q-ID; "buildings in Boston" → building
                                  Q-ID (Q41176).
        region_*                — Mode A/B region when the prompt names a
                                  place ("…in Boston", "…in Paris"). REQUIRED
                                  for "<subject> in <place>" prompts.
        combined_qid            — Optional Q-ID for an already-combined
                                  concept ("Millennium Park, Chicago"
                                  Q1130516 → its own P373 category). Rarely
                                  needed now (see below).
        commons_intitle_fallback — Only when no Q-ID has a clean P373:
                                   a SINGLE distinctive keyword, matched as a
                                   literal title substring. Real Commons files
                                   are titled "Chicago skyline.jpg", "Boston
                                   lighthouse.jpg" — so give the bare noun that
                                   appears in those titles, usually SINGULAR:
                                   "skyline", "lighthouse", "waterfall". NEVER a
                                   descriptive phrase ("city skylines", "tall
                                   skyscrapers"): a multi-word value must appear
                                   verbatim in the title and almost never does
                                   (intitle:"city skylines" ≈ 1 hit nationwide,
                                   intitle:skyline ≈ thousands per city).

      What the backend does with these (you don't engineer around it):
        * topic_qid + region → it builds the REGION-ANCHORED category
          "<TopicCategory> in <Region>" (e.g. "Buildings in Boston") and
          deepcategory-searches that + nearcoord of the region. This is
          why you must give BOTH a generic subject AND the region: the
          bare root category ("Buildings") is too huge for Commons to
          expand and returns almost nothing on its own.
        * topic_qid with NO region → it anchors nearcoord: on the
          subject's OWN coordinates (the topic's P625), pruning pollution
          and far-flung mistagged files. Use this for single-subject
          prompts: "Mount Fuji photos" → topic_qid only.

      Search for the topic Q-ID via search_wikidata. The rule depends on
      whether the prompt names a SUBJECT:
        * Prompt names a subject (a noun: "buildings", "churches", "street
          art") → that noun is the topic_qid; the place goes in region_*.
          Do NOT make the place the topic (topic_qid for "Boston" alongside
          a real subject surfaces "People photographed in Boston").
        * Prompt names NO subject — a bare "photos of <city>" → the city
          itself is the topic_qid. This is acceptable but broad (a city
          category holds maps, documents and people too, only partly pruned
          by the coordinate anchor). If the user more likely wants varied
          on-the-ground imagery, prefer mapillary instead.

      Don't set sparql_pattern for commons.

      MAPILLARY SOURCE (image_source: "mapillary"):

      Street-level imagery via Mapillary's vector tiles. ALWAYS requires
      a region (Mode A or B). The backend samples z=14 tiles spread evenly
      across the region (a city gets full coverage; a state/country gets a
      distributed sample), so any region size works — you just supply the
      region, never a zoom.

      Provide:
        region_*               — Mode A or B (required).
        region_radius_meters   — Optional, for "near X" prompts.
        mapillary_min_year     — Optional string like "2023" — only
                                 include images captured during or after
                                 that year. Use when the user says
                                 "recent" or names a year.

      Don't set topic_qid, combined_qid, sparql_pattern.

      Panoramas (360° images) are always excluded. If the user
      explicitly asks for "360 panoramas" or "VR street view", refuse
      with cannot_answer=true and: "Our viewer doesn't support 360
      panoramas yet — I can give you regular street imagery instead."

      EXAMPLE FLOWS

      Country-level Wikidata (use wdt:P17 in SPARQL, no region_*) —
      user: "volcanoes in Japan"

        search_wikidata("volcano") → Q8072 "type of mountain" ✓
        search_wikidata("Japan")   → Q17  "country in East Asia" ✓
        submit_answer(
          image_source: "wikidata",
          sparql_pattern: "?item wdt:P31/wdt:P279* wd:Q8072 ; wdt:P17 wd:Q17 ; wdt:P625 ?coord .",
          set_name: "Volcanoes of Japan",
          explanation: "I'll find volcanoes located in Japan that have photos.",
          cannot_answer: false
        )

      Sub-national Wikidata (Mode A, NO geo in SPARQL) —
      user: "lakes in Massachusetts"

        search_wikidata("lake") → Q23397 "body of water" ✓
        submit_answer(
          image_source: "wikidata",
          sparql_pattern: "?item wdt:P31/wdt:P279* wd:Q23397 ; wdt:P625 ?coord .",
          set_name: "Lakes in Massachusetts",
          explanation: "I'll find lakes located in Massachusetts that have photos.",
          cannot_answer: false,
          region_name: "Massachusetts",
          region_parent_name: "United States",
          region_admin_level: "admin1"
        )

      Mapillary streets in a city (Mode A) —
      user: "streets in Chicago"

        submit_answer(
          image_source: "mapillary",
          set_name: "Streets of Chicago",
          explanation: "I'll pull street-level photos from across Chicago.",
          cannot_answer: false,
          region_name: "Chicago",
          region_parent_name: "Illinois",
          region_admin_level: "city"
        )

      Mapillary in a sub-city neighborhood (Mode B) —
      user: "streets in Shibuya"

        geocode(queries: ["Shibuya, Tokyo"])
          → boundary/administrative, lat 35.66 lng 139.70  ✓
        submit_answer(
          image_source: "mapillary",
          set_name: "Streets of Shibuya",
          explanation: "Street imagery from across Shibuya.",
          cannot_answer: false,
          region_pois: ["Shibuya, Tokyo"]
        )

      Mapillary with radius around a landmark —
      user: "streets near the Eiffel Tower"

        geocode(queries: ["Eiffel Tower"])
          → man_made/tower, lat 48.86 lng 2.29, importance 0.62  ✓
        submit_answer(
          image_source: "mapillary",
          set_name: "Streets Near the Eiffel Tower",
          explanation: "Street photos within ~2 km of the Eiffel Tower.",
          cannot_answer: false,
          region_pois: ["Eiffel Tower"],
          region_radius_meters: 2000
        )

      Commons single subject (no region) —
      user: "Mount Fuji photos"

        search_wikidata("Mount Fuji") → Q39231 "volcano in Japan" ✓
        submit_answer(
          image_source: "commons",
          topic_qid: "Q39231",
          set_name: "Mount Fuji",
          explanation: "I'll gather Commons photos from the Mt Fuji category.",
          cannot_answer: false
        )

      Commons topic + region —
      user: "many photos of buildings in Boston"

        search_wikidata("building") → Q41176 ✓
        submit_answer(
          image_source: "commons",
          topic_qid: "Q41176",
          set_name: "Buildings in Boston",
          explanation: "I'll pull thousands of building photos from Commons within Boston.",
          cannot_answer: false,
          region_name: "Boston",
          region_parent_name: "Massachusetts",
          region_admin_level: "city"
        )

      Living things → Commons, NOT Wikidata (no geotagged taxa) —
      user: "wildlife in Kenya"

        search_wikidata("wildlife") → animal/taxon concepts — NOT geotaggable.
        (A Wikidata `?item wdt:P31/wdt:P279* wd:Q729 ; wdt:P17 wd:Q114` returns
         0: Wikidata has species, not located specimens.) Route to Commons:
        submit_answer(
          image_source: "commons",
          topic_qid: "Q729",     # animal — backend builds "Animals in Kenya" + nearcoord
          set_name: "Wildlife in Kenya",
          explanation: "I'll gather geotagged wildlife photos from Commons across Kenya.",
          cannot_answer: false,
          region_name: "Kenya",
          region_admin_level: "country"
        )

      Refusal example —
      user: "north half of Chicago"

        submit_answer(
          image_source: "mapillary",
          cannot_answer: true,
          set_name: "North Half of Chicago",
          explanation: "I can't do directional splits yet. I can import all of Chicago and you can then use the filter-by-area feature on the show page to keep only the north half."
        )
    PROMPT
  end
end
