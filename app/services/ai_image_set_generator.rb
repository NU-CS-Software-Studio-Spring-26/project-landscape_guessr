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

  FLASH_MODEL = "gemini-2.5-flash".freeze
  PRO_MODEL   = "gemini-2.5-pro".freeze
  API_BASE    = "https://generativelanguage.googleapis.com/v1beta/models".freeze

  # Cap the function-call cycle. The AI typically resolves 2-4 Q-IDs per
  # query, plus the final submit_answer — so 8 turns is generous. Going
  # over means the AI is stuck in a loop; better to fail and let the
  # user refine.
  MAX_TOOL_ROUNDS = 8

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
            sparql_pattern:     { type: "STRING" },
            set_name:           { type: "STRING" },
            explanation:        { type: "STRING" },
            cannot_answer:      { type: "BOOLEAN" },
            # Sub-national region filter. Flat fields (not a nested OBJECT)
            # — nested schemas trigger MALFORMED on Flash. Backend looks up
            # the region in our pre-indexed Region table and injects a BBOX
            # FILTER into the SPARQL; the AI MUST NOT include wdt:P131* or
            # any geo constraint of its own when these are set. Country-
            # level filters stay on wdt:P17 (direct property, cheap).
            region_name:        { type: "STRING" },
            region_parent_name: { type: "STRING" },
            region_admin_level: { type: "STRING" }
          },
          required: %w[sparql_pattern set_name explanation cannot_answer]
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
    malformed_retries = 0
    started = Time.now
    gemini_time = 0.0
    tool_time = 0.0
    tool_counts = Hash.new(0)

    MAX_TOOL_ROUNDS.times do |i|
      t0 = Time.now
      response = call_gemini(contents)
      gemini_time += Time.now - t0
      candidate = response.dig("candidates", 0) || {}
      parts = candidate.dig("content", "parts") || []
      if parts.empty?
        finish = candidate["finishReason"]
        # MALFORMED_FUNCTION_CALL is non-deterministic on Flash with
        # multi-round prompts — retry the SAME conversation once or twice
        # before giving up. The retry uses temperature 0.0 already so
        # we'd ordinarily expect determinism, but Flash structured-output
        # behavior has stochastic edge cases.
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
        log_generate_summary(started, gemini_time, tool_time, tool_counts)
        return parse_submit(submit["functionCall"]["args"])
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
          allowedFunctionNames: %w[search_wikidata inspect_entity submit_answer]
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
    else
      { error: "unknown function: #{name}" }
    end
  end

  # Validate + return the submit_answer payload. Defensive checks even
  # though Gemini's parameter schema should enforce required fields;
  # the AI occasionally violates schemas in practice.
  def parse_submit(args)
    payload = {
      sparql_pattern: args["sparql_pattern"].to_s,
      set_name:       args["set_name"].to_s.strip.presence || "Untitled AI Set",
      explanation:    args["explanation"].to_s.strip,
      cannot_answer:  args["cannot_answer"] == true,
      region_filter:  build_region_filter(args)
    }

    return payload if payload[:cannot_answer]

    raise InvalidResponseError, "submit_answer with empty sparql_pattern" if payload[:sparql_pattern].strip.empty?

    # Block any keyword that either breaks our outer wrapping or could
    # let the AI take the query somewhere we don't control. WDQS is
    # read-only so INSERT/DELETE/etc would 4xx anyway, but defense in
    # depth is cheap: a future endpoint with write capability would
    # silently inherit the gap.
    #   SELECT/LIMIT       — collide with our outer SELECT + cap
    #   SERVICE            — arbitrary endpoint calls
    #   DESCRIBE/ASK/CONSTRUCT — alternate query forms; bypass our wrap
    #   INSERT/DELETE/LOAD/CLEAR/DROP/WITH — SPARQL Update; should never appear
    # OPTIONAL/FILTER/UNION inside the pattern are fine; SPARQL allows
    # them alongside the OPTIONAL+FILTER trailer we add and they're
    # often necessary (numeric thresholds, alternatives, etc).
    %w[SELECT LIMIT SERVICE DESCRIBE ASK CONSTRUCT INSERT DELETE LOAD CLEAR DROP WITH].each do |kw|
      if payload[:sparql_pattern] =~ /\b#{kw}\b/i
        raise InvalidResponseError, "AI returned #{kw} in sparql_pattern (not allowed)"
      end
    end

    payload
  end

  # Assemble the region_filter hash from the three flat AI fields. Returns
  # nil unless we have BOTH a name and a recognized admin_level; missing
  # parent_name is OK for countries (no parent) but lookup may be ambiguous
  # without it for "Georgia" the state vs "Georgia" the country.
  ALLOWED_ADMIN_LEVELS = %w[continent country admin1 admin2 city].freeze

  def build_region_filter(args)
    name        = args["region_name"].to_s.strip.presence
    level       = args["region_admin_level"].to_s.strip.presence
    parent_name = args["region_parent_name"].to_s.strip.presence
    return nil unless name && ALLOWED_ADMIN_LEVELS.include?(level)
    { name: name, parent_name: parent_name, admin_level: level }
  end

  def system_prompt
    <<~PROMPT
      You generate Wikidata SPARQL graph patterns for an image-set
      creation tool. The user describes images they want. You reason
      about how Wikidata models that intent, resolve every Q-ID via
      the search_wikidata tool, then call submit_answer with the
      final SPARQL pattern.

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
        and assumes that name. MUST NOT contain SELECT, LIMIT, or
        SERVICE blocks — the server adds those, plus its own
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

      - **Sovereign filtering.** If "country" must mean an actual
        sovereign nation (not territory/region), search for the
        sovereign-state concept Q-ID and constrain with that.

      - **Multi-country regions** ("Scandinavia", "South America"):
        `VALUES ?country { wd:QA wd:QB ... } . ?item wdt:P17 ?country` —
        search each country Q-ID first.

      - **Umbrella concepts that span multiple classes.** Applies ONLY
        when the user's request is a vibe / domain / feeling and no
        single Wikidata class captures it. Examples that ARE umbrellas:
        "nature", "wildlife", "transportation", "architecture",
        "sports". Examples that are NOT umbrellas (these are specific
        classes — use a single type, do not enumerate): "rivers
        worldwide", "volcanoes worldwide", "skyscrapers in Asia",
        "birds in Brazil". Broad scope ≠ umbrella; only enumerate when
        no single class fits.

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
        region's bounding box from our Region table and prepends
        SERVICE wikibase:box to your pattern. You MUST NOT compose
        wdt:P131* or any other geo constraint when region_name is set.
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

      REGION FILTERS:

      For COUNTRY-level filtering, use `wdt:P17 wd:Q##` in your
      SPARQL — direct property, cheap, works in WDQS.

      For SUB-NATIONAL regions (US states, provinces, counties,
      cities), DO NOT use `wdt:P131*` in your SPARQL — it reliably
      times out WDQS. Instead set the region_name / region_parent_name
      / region_admin_level fields. The backend looks the region up in
      our pre-indexed region table and injects a BBOX filter for you.

      When you set the region fields, your sparql_pattern must NOT
      include any geo constraint — just class + coord:

        sparql_pattern:        "?item wdt:P31/wdt:P279* wd:Q23397 ; wdt:P625 ?coord ."
        region_name:           "Massachusetts"
        region_parent_name:    "United States"
        region_admin_level:    "admin1"

      REGION FIELD RULES:
      - region_name: Canonical English name. "United States" not
        "USA"; "Germany" not "Deutschland"; "Bavaria" not "Bayern".
        Lookup uses GeoNames data which only has English forms.
      - region_parent_name: Parent administrative region's English
        name. For admin1, the country ("United States"). For city,
        the admin1 or admin2 ("Massachusetts" for Cambridge MA,
        "Cambridgeshire" for Cambridge UK).
      - region_admin_level: exactly one of "country", "admin1"
        (states/provinces), "admin2" (counties), "city".
      - Omit ALL three fields when the user's "region" isn't a formal
        admin unit ("the South", "Northern California", "the Mediterranean
        coast"). Either reinterpret as a country/state, or refuse.
      - For country-level filtering, leave region fields empty and
        use `wdt:P17 wd:Q##` in the pattern as before — countries
        have weirdly-shaped bboxes (Russia, USA) so direct P17 is
        more accurate.

      EXPLANATION STYLE:
      - Plain English, friendly, no jargon.
      - Bad: "Filters wd:Q8072 via wdt:P31/wdt:P279* with wdt:P17 wd:Q17."
      - Good: "I'll find volcanoes located in Japan that have photos."
      - If your query doesn't fully cover the user's request, name the
        part you couldn't honor and offer to adjust. Don't silently
        drop pieces of their ask.
      - When cannot_answer=true, suggest the nearest workable
        alternative if one exists. Avoid bare "I can't" dead-ends.

      EXAMPLE FLOWS

      Country-level (use wdt:P17 in SPARQL, no region_* fields) —
      user: "volcanoes in Japan"

        search_wikidata("volcano") → Q8072 "type of mountain" ✓
        search_wikidata("Japan")   → Q17  "country in East Asia" ✓
        submit_answer(
          sparql_pattern: "?item wdt:P31/wdt:P279* wd:Q8072 ; wdt:P17 wd:Q17 ; wdt:P625 ?coord .",
          set_name: "Volcanoes of Japan",
          explanation: "I'll find volcanoes located in Japan that have photos.",
          cannot_answer: false
        )

      Sub-national (use region_* fields, NO geo in SPARQL) —
      user: "lakes in Massachusetts"

        search_wikidata("lake") → Q23397 "body of water" ✓
        (no need to search "Massachusetts" — the backend resolves it)
        submit_answer(
          sparql_pattern: "?item wdt:P31/wdt:P279* wd:Q23397 ; wdt:P625 ?coord .",
          set_name: "Lakes in Massachusetts",
          explanation: "I'll find lakes located in Massachusetts that have photos.",
          cannot_answer: false,
          region_name: "Massachusetts",
          region_parent_name: "United States",
          region_admin_level: "admin1"
        )
    PROMPT
  end
end
