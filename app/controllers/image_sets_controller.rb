class ImageSetsController < ApplicationController
  before_action :set_image_set, only: %i[show edit update destroy locations update_locations add_image attach_blob processing_status remove_item map new_filtered edit_filter update_filter preview_filter_count import_status retry_import]
  before_action :require_owner, only: %i[edit update destroy locations update_locations add_image attach_blob processing_status remove_item edit_filter update_filter preview_filter_count retry_import import_status]
  # Filtered sets' items are derived from the filter — any direct edit gets
  # blown away on the next materialize. Redirect those routes to the filter
  # editor instead of letting users do work that disappears.
  before_action :block_if_filtered, only: %i[locations update_locations add_image attach_blob remove_item]

  # GET /image_sets
  def index
    with_counts = ->(scope) {
      scope.left_joins(:image_set_items)
           .group("image_sets.id")
           .select("image_sets.*, COUNT(image_set_items.id) AS items_count")
    }
    @my_sets     = with_counts.call(ImageSet.owned_by(Current.user)).order(:name)
    @public_sets = with_counts.call(ImageSet.public_catalog).order(:name)
  end

  # GET /image_sets/1
  #
  # Paginated to keep the DOM bounded. Default 100/page (matches the rest
  # of the app); users can bump up to 500 via the per-page picker for
  # URL-only sets like Wikimedia, where there are no signed-URL costs.
  # `loading="lazy"` on the <img> tags below defers thumbnail GETs until
  # each card scrolls into view.
  def show
    @items = paginate(
      @image_set.effective_items
                .joins(:image)
                .includes(image: { photo_attachment: :blob })
                .order("images.title"),
      per_page: 100
    )
  end

  # GET /image_sets/new
  def new
    @image_set = ImageSet.new(visibility: "private")
  end

  # POST /image_sets
  def create
    @image_set = Current.user.image_sets.new(image_set_params)

    # Filtered sets can only be built from a parent the user can play. Without
    # this check, anyone could pass parent_image_set_id of a private set they
    # don't own and clone its image_set_items into a set they then mark public.
    if @image_set.parent_image_set_id.present?
      parent = ImageSet.find_by(id: @image_set.parent_image_set_id)
      unless parent&.playable_by?(Current.user)
        @image_set.errors.add(:parent_image_set, "is not accessible")
        @parent_set = parent
        @filtered_set = @image_set
        render :new_filtered, status: :unprocessable_entity and return
      end
    end

    if @image_set.filtered?
      if @image_set.save
        @image_set.materialize_filtered_items!
        redirect_to @image_set, notice: "Filtered set created (#{@image_set.image_set_items.count} images matched)."
      else
        @parent_set = @image_set.parent_image_set
        @filtered_set = @image_set
        render :new_filtered, status: :unprocessable_entity
      end
    else
      if @image_set.save
        redirect_to locations_image_set_path(@image_set), notice: "Set created — add some images to start."
      else
        render :new, status: :unprocessable_entity
      end
    end
  end

  # GET /image_sets/1/edit
  def edit
  end

  # PATCH/PUT /image_sets/1
  def update
    if @image_set.update(image_set_params)
      redirect_to @image_set, notice: "Image set updated."
    else
      render :edit, status: :unprocessable_entity
    end
  end

  # DELETE /image_sets/1
  def destroy
    @image_set.destroy!
    redirect_to image_sets_path, notice: "Image set deleted."
  end

  # GET /image_sets/1/locations
  def locations
    # Stable order by item id — title-ordering would re-shuffle rows after
    # the user edits a title or saves, making them think their edits got
    # lost. Newest items always appear at the end.
    @items = paginate(
      @image_set.image_set_items.includes(image: { photo_attachment: :blob }).order(:id),
      per_page: 100
    ).load
    # Banner reflects only items on the current page; for huge sets this
    # avoids loading every blob's metadata. Real upload batches almost
    # always fit on one page anyway, so the banner is still accurate
    # where it matters.
    @processing_count = @items.count { |i| !i.image.processed? }
  end

  # PUT /image_sets/1/locations
  #
  # Bulk-edit form: per-item lat/lng (on ImageSetItem) and title (on the
  # underlying Image). We update Image#title because ImageSetItem doesn't
  # carry its own title — ImageSetItem#title delegates to its Image. In
  # the rare case that an Image lives in another user's set too, that
  # set's display title will follow this edit.
  def update_locations
    items_params = params[:image_set_items] || {}
    errors = []

    ImageSetItem.transaction do
      items_params.each do |item_id, attrs|
        item = @image_set.image_set_items.find_by(id: item_id)
        next unless item

        unless item.update(latitude: attrs[:latitude], longitude: attrs[:longitude])
          errors << "#{item.title}: #{item.errors.full_messages.join(', ')}"
        end

        if attrs.key?(:title) && (new_title = attrs[:title].to_s.strip).present? && new_title != item.image.title
          # Mirror Image#editable_by? — set-owner CAN edit Image#title
          # in the general case, but NOT for default-set images, since
          # the canonical title propagates to the default set everyone
          # plays. require_owner alone isn't enough here; without this
          # guard, any user could vandalize default-set titles by
          # adding the same URL to their own set first.
          if item.image.editable_by?(Current.user)
            unless item.image.update(title: new_title)
              errors << "#{item.title}: #{item.image.errors.full_messages.join(', ')}"
            end
          else
            errors << "#{item.title}: title is locked because this image is in the default set"
          end
        end
      end
      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      # Re-render with the SAME per_page as locations#GET so the user
      # sees the page they were editing. (Previous code used 25, which
      # silently shuffled them to a different slice on validation error.)
      # paginate(...) already honors ?per_page= when valid.
      @items = paginate(
        @image_set.image_set_items.includes(image: { photo_attachment: :blob }).order(:id),
        per_page: 100
      ).load
      @processing_count = @items.count { |i| !i.image.processed? }
      flash.now[:alert] = errors.join("; ")
      render :locations, status: :unprocessable_entity
    else
      # Preserve the page + per_page the user was on so they don't get
      # bounced back to page 1 / default size after every save.
      redirect_to locations_image_set_path(@image_set, page: params[:page], per_page: params[:per_page]),
                  notice: "Changes saved."
    end
  end

  # POST /image_sets/1/add_image
  #
  # Add a single image *by URL* — for external images we don't need to
  # store on S3 (Wikimedia, etc.). File uploads go through attach_blob
  # (direct-upload + ProcessImageJob), not here.
  def add_image
    url = params[:url].to_s.strip
    if url.empty?
      redirect_back fallback_location: locations_image_set_path(@image_set), alert: "Please enter an image URL." and return
    end

    title = params[:title].to_s.strip.presence || "Untitled"
    lat   = params[:latitude].presence&.to_f
    lng   = params[:longitude].presence&.to_f

    image = Image.find_or_create_by!(url: url) do |img|
      img.title     = title
      img.latitude  = lat
      img.longitude = lng
    end

    item = @image_set.image_set_items.find_or_initialize_by(image: image)
    if item.new_record?
      item.latitude  = lat || image.latitude
      item.longitude = lng || image.longitude
      item.save!
      refresh_filtered_children
      redirect_back fallback_location: locations_image_set_path(@image_set), notice: "Image added to set."
    else
      redirect_back fallback_location: locations_image_set_path(@image_set), alert: "That image is already in this set."
    end
  end

  # DELETE /image_sets/1/items/123
  def remove_item
    item = @image_set.image_set_items.find_by(id: params[:item_id])
    if item
      item.destroy
      refresh_filtered_children
      redirect_back fallback_location: @image_set, notice: "Image removed from set."
    else
      redirect_back fallback_location: @image_set, alert: "Image not found in this set."
    end
  end

  # GET /image_sets/1/map
  def map
    items = @image_set.effective_items.joins(:image).includes(image: { photo_attachment: :blob })
    @image_data = items.filter_map do |item|
      lat = item.latitude || item.image.latitude
      lng = item.longitude || item.image.longitude
      next unless lat && lng
      img = item.image
      { id: img.id, lat: lat.to_f, lng: lng.to_f, title: item.title, url: view_context.image_src(img) }
    end

    respond_to do |format|
      format.html
      format.json { render json: @image_data }
    end
  end

  # GET /image_sets/1/processing_status
  #
  # Lightweight JSON endpoint the locations page polls every couple
  # seconds while ProcessImageJob is finishing background work, so we
  # can swap "Processing..." placeholders for real thumbnails without
  # full page reloads.
  def processing_status
    items = @image_set.image_set_items.includes(image: { photo_attachment: :blob })
    payload = items.map do |item|
      processed = item.image.processed?
      {
        id:        item.id,
        processed: processed,
        photo_url: processed ? view_context.image_src(item.image, width: 200) : nil
      }
    end
    render json: { items: payload, processing_count: payload.count { |i| !i[:processed] } }
  end

  # GET /image_sets/1/preview_filter_count?region_ids[]=N&custom_areas=[...]
  # Returns the number of parent-set images that would match the given regions
  # AND custom areas, plus the matched IDs so the builder can recolor image
  # dots on the map.
  def preview_filter_count
    region_ids = Array(params[:region_ids]).map(&:to_i).reject(&:zero?)
    areas = sanitize_custom_areas(params[:custom_areas])
    if region_ids.empty? && areas.empty?
      render json: { count: 0, matched_ids: [] } and return
    end

    parent = @image_set.filtered? ? @image_set.parent_image_set : @image_set
    temp = ImageSet.new(parent_image_set: parent, region_ids: region_ids, custom_areas: areas)
    matched = temp.compute_matching_image_ids
    render json: { count: matched.size, matched_ids: matched }
  rescue => e
    Rails.logger.error("[image_sets#preview_filter_count] #{e.class}: #{e.message}")
    render json: { count: nil, error: "Unable to count matching images" }, status: :unprocessable_entity
  end

  # GET /image_sets/1/new_filtered
  def new_filtered
    @parent_set = @image_set
    @filtered_set = ImageSet.new(
      parent_image_set: @parent_set,
      visibility: @parent_set.visibility,
      map_style: @parent_set.map_style
    )
  end

  # GET /image_sets/1/edit_filter
  def edit_filter
    @parent_set = @image_set.parent_image_set
    @filtered_set = @image_set
  end

  # PATCH /image_sets/1/update_filter
  def update_filter
    region_ids = Array(params[:region_ids]).map(&:to_i).reject(&:zero?)
    if @image_set.update(
      name: params[:name],
      region_ids: region_ids,
      custom_areas: sanitize_custom_areas(params[:custom_areas]),
      visibility: params[:visibility] || @image_set.visibility
    )
      @image_set.materialize_filtered_items!
      redirect_to @image_set, notice: "Filter updated (#{@image_set.image_set_items.count} images matched)."
    else
      @parent_set = @image_set.parent_image_set
      @filtered_set = @image_set
      render :edit_filter, status: :unprocessable_entity
    end
  end

  # POST /image_sets/1/attach_blob
  #
  # Direct-upload flow: the JS direct-upload controller (see
  # app/javascript/controllers/direct_upload_controller.js) PUTs each
  # original (HEIC/JPEG/...) straight to S3 via DirectUpload, then calls
  # here once per file with the blob's signed_id. We attach the blob to
  # a new Image, add it to the set, and enqueue ProcessImageJob to do
  # the libvips work in the background. The web dyno never sees the
  # original bytes -> no R14, no H12.
  #
  # Per-file rather than per-batch: anything already attached survives a
  # tab close mid-upload, and a single bad file in a 91-image batch
  # doesn't strand all the prior uploads.
  def attach_blob
    signed_id = params[:signed_id].to_s.strip
    return render json: { error: "missing signed_id" }, status: :bad_request if signed_id.empty?

    blob = ActiveStorage::Blob.find_signed(signed_id)
    return render json: { error: "invalid signed_id" }, status: :not_found unless blob

    title = File.basename(blob.filename.to_s, ".*").gsub(/[_-]+/, " ").titleize
    image = Image.create!(title: title)
    image.photo.attach(blob)

    item = @image_set.image_set_items.find_or_initialize_by(image: image)
    item.save! if item.new_record?

    ProcessImageJob.perform_later(image)
    render json: { image_id: image.id, status: "ok" }
  rescue => e
    Rails.logger.error "[image_sets#attach_blob] #{e.class}: #{e.message}"
    render json: { error: e.message }, status: :unprocessable_entity
  end

  # GET /image_sets/ai_new
  # Renders either the fresh form, an in-progress poll banner, or the
  # completed/failed result — branched on the optional ?generation_id
  # param. Each `Send` click creates a NEW AiGeneration record and
  # redirects here with its id; the page state is entirely driven by
  # that record.
  def ai_new
    @ai_generation = load_ai_generation(params[:generation_id])
  end

  # POST /image_sets/ai_generate
  #
  # Creates one AiGeneration record per submit, enqueues the
  # AiGenerationJob to actually run Gemini + Wikidata off-thread, then
  # redirects to ai_new with the new record's id. The browser polls
  # /ai_generations/:id/status and reloads when the job finishes.
  def ai_generate
    if ai_rate_limited?
      @ai_daily_limit = AI_DAILY_LIMIT
      @ai_used_today  = AiUsage.today_count(user: Current.user)
      render :ai_rate_limited, status: :too_many_requests and return
    end

    user_msg = params[:user_message].to_s.strip
    if user_msg.empty?
      redirect_to ai_new_image_sets_path, alert: "Type a prompt first." and return
    end

    prior_conv = parse_conversation(params[:conversation_json])
    bounded_msg = user_msg.first(8000)

    # Bump BEFORE enqueue (changed from prior post-success bump).
    # Async architecture needs queue-flood protection, and Gemini bills
    # us per attempt regardless of success — counting attempts is more
    # honest. A user who hits a transient failure can retry within
    # their remaining quota; transient failures are rare in practice.
    bump_ai_rate_limit_counter

    # Include the new user turn in conversation_json AT CREATE TIME, not
    # in the job. Otherwise the brief pending/running window between
    # redirect and the job's first tick would show the thread missing
    # the message the user just typed.
    new_conv = prior_conv + [ { role: "user", text: bounded_msg } ]

    gen = Current.user.ai_generations.create!(
      status:            "pending",
      conversation_json: new_conv.to_json,
      user_message:      bounded_msg
    )
    AiGenerationJob.perform_later(gen.id)
    redirect_to ai_new_image_sets_path(generation_id: gen.id)
  end

  # GET /ai_generations/:id/status
  #
  # Lightweight JSON the poll controller hits every ~1.5s while the
  # AiGenerationJob runs. Scoped to current user via the association
  # — cross-user IDs 404 by way of ActiveRecord::RecordNotFound. The
  # `stale?` check downgrades stuck-running records (worker crash, queue
  # offline) to a synthetic `failed` so the UI eventually unfreezes.
  def ai_generation_status
    gen = Current.user.ai_generations.find(params[:id])
    effective = gen.stale? ? "failed" : gen.status
    render json: {
      status:           effective,
      phase:            gen.phase,
      progress_message: gen.progress_message,
      result_count:     gen.result_count, # known once counting phase finishes
      error:            gen.stale? ? "Generation timed out — try again." : gen.error
    }
  rescue ActiveRecord::RecordNotFound
    render json: { error: "not found" }, status: :not_found
  end

  # POST /image_sets/ai_create
  #
  # User has approved the preview. We source the AI fields (sparql
  # pattern, explanation, model) from the AiGeneration record — not
  # from hidden form fields — so a user can't bypass parse_submit's
  # SPARQL validation by editing the hidden `ai_query` in devtools.
  def ai_create
    gen = Current.user.ai_generations.find_by(id: params[:generation_id])
    if gen.nil? || gen.status != "completed" || gen.result.nil? ||
       gen.result[:cannot_answer] ||
       gen.result[:sparql_pattern].to_s.strip.empty?
      # Last condition guards against a generation that completed but
      # whose result has no usable pattern (would create a set whose
      # import job runs nil SPARQL).
      redirect_to ai_new_image_sets_path, alert: "No AI proposal to import." and return
    end

    result = gen.result
    fetch_strategy = if %w[exhaustive random_sample].include?(result[:fetch_strategy])
      result[:fetch_strategy]
    else
      "exhaustive"
    end

    image_set = Current.user.image_sets.new(
      name:              params[:name].to_s.strip.presence || result[:set_name].presence || "Untitled AI Set",
      visibility:        %w[public private].include?(params[:visibility]) ? params[:visibility] : "private",
      ai_prompt:         gen.user_message.to_s,
      ai_query:          result[:sparql_pattern],
      ai_explanation:    result[:explanation].to_s,
      ai_model:          gen.model_used.presence || "flash",
      ai_fetch_strategy: fetch_strategy,
      ai_region_filter:  result[:region_filter],
      import_state:      "pending"
    )

    if image_set.save
      AiImportImagesJob.perform_later(image_set.id)
      redirect_to image_set, notice: "Set created — importing images in the background."
    else
      redirect_to ai_new_image_sets_path, alert: image_set.errors.full_messages.join("; ")
    end
  end

  # POST /ai_generations/:id/cancel
  #
  # Flip the row to "canceled" so the polling UI stops + the pipeline
  # bails at its next phase checkpoint. In-flight Wikidata threads
  # finish on their own (we can't interrupt mid-Net::HTTP cleanly) but
  # their results are discarded. Idempotent: cancelling an already-
  # completed/failed generation is a no-op.
  def ai_generation_cancel
    gen = Current.user.ai_generations.find(params[:id])
    if gen.in_progress?
      gen.update!(status: "canceled", phase: nil, progress_message: nil)
    end
    redirect_to ai_new_image_sets_path
  rescue ActiveRecord::RecordNotFound
    redirect_to ai_new_image_sets_path
  end

  # POST /image_sets/1/retry_import
  #
  # Re-runs the import for an AI set when the previous attempt didn't
  # finish. Common cases:
  #   - state == "failed": transient WDQS hiccup outlasted run_query's
  #     3-attempt internal retry, or Gemini timed out
  #   - state stuck in fetching/looking_up_images/inserting: worker crashed
  #     mid-job, or the AsyncAdapter thread died, or the import is
  #     taking longer than the user wants to wait
  #
  # We allow retry from any non-completed AI state for the owner. Safety:
  #   - Image.insert_all uses unique_by: :url so two concurrent imports
  #     racing on the same row don't duplicate Images
  #   - ImageSetItem has a unique index on (image_set_id, image_id) so
  #     the join rows also dedupe
  # Worst case of a real concurrent import: the progress counter ping-pongs
  # briefly, but the final state converges. That's an acceptable trade-off
  # for letting the user un-stick a stuck job without us needing per-import
  # timestamp tracking.
  def retry_import
    if @image_set.ai_query.blank?
      redirect_to @image_set, alert: "This isn't an AI-generated set, nothing to retry." and return
    end
    if @image_set.import_state == "completed"
      redirect_to @image_set, alert: "Import already completed — nothing to retry." and return
    end

    @image_set.update_columns(
      import_state:    "pending",
      import_error:    nil,
      import_progress: 0,
      import_total:    0
    )
    AiImportImagesJob.perform_later(@image_set.id)
    redirect_to @image_set, notice: "Re-importing images in the background."
  end

  # GET /image_sets/1/import_status
  #
  # Lightweight JSON for the show page's polling banner. Returns the
  # current import state + progress so the UI can render a progress bar
  # without a full page reload.
  def import_status
    render json: {
      state:    @image_set.import_state,
      progress: @image_set.import_progress.to_i,
      total:    @image_set.import_total.to_i,
      error:    @image_set.import_error
    }
  end

  private

  def set_image_set
    # The remove_item route is a non-member nested DELETE, so its parent id
    # comes through as :image_set_id, not :id like the member routes do.
    # Without this fallback, ImageSet.find(nil) raised RecordNotFound and
    # the remove flow appeared to fail to the user.
    @image_set = ImageSet.find(params[:id] || params[:image_set_id])
    # Allow reading public/system sets; editing is guarded by require_owner.
    unless @image_set.playable_by?(Current.user)
      redirect_to image_sets_path, alert: "That set is private." and return
    end
  end

  def require_owner
    return if @image_set.owned_by?(Current.user)
    # JSON callers (poll banners, fetch-based UIs) need a JSON 403 — an
    # HTML redirect comes back as 302→200, content-type text/html, and
    # the poll's `res.json()` throws on the HTML body. Other formats keep
    # the friendly redirect.
    respond_to do |format|
      format.json { render json: { error: "forbidden" }, status: :forbidden }
      format.any  { redirect_to @image_set, alert: "You don't have permission to edit this set." }
    end
  end

  def block_if_filtered
    if @image_set.filtered?
      msg = "This is a filtered set — edit the filter instead. Direct image changes get overwritten."
      respond_to do |format|
        format.html { redirect_to edit_filter_image_set_path(@image_set), alert: msg }
        format.json { render json: { error: msg }, status: :forbidden }
      end
    end
  end

  # On `create`, parent_image_set_id + region_ids + custom_areas are needed
  # (that's how a filtered set is born). On `update`, all three must be locked:
  # the filter is only mutable through update_filter, which re-runs materialize.
  # Allowing them through the regular update would silently desync materialized
  # items from the recorded filter.
  def image_set_params
    allowed = [ :name, :visibility, :map_style ]
    if action_name == "create"
      allowed += [ :parent_image_set_id, :custom_areas_json, { region_ids: [] } ]
    end
    permitted = params.expect(image_set: allowed)
    if permitted[:region_ids].present?
      permitted[:region_ids] = permitted[:region_ids].map(&:to_i).reject(&:zero?)
    else
      permitted.delete(:region_ids)
    end
    # The form posts custom_areas as a JSON string in a single hidden field —
    # nested-params would require arbitrary-depth permits, but the data is
    # client-controlled JSON anyway, so we round-trip through the sanitizer.
    if permitted[:custom_areas_json].present?
      permitted[:custom_areas] = sanitize_custom_areas(permitted.delete(:custom_areas_json))
    else
      permitted.delete(:custom_areas_json)
    end
    permitted
  end

  # Returns an array of validated custom-area hashes — strict shape, bounded
  # field values. Untrusted input from the client.
  MAX_CUSTOM_AREAS = 50
  MIN_CIRCLE_RADIUS_M = 100
  MAX_CIRCLE_RADIUS_M = 5_000_000

  def sanitize_custom_areas(raw)
    return [] if raw.blank?
    raw = JSON.parse(raw) if raw.is_a?(String)
    return [] unless raw.is_a?(Array)
    raw.first(MAX_CUSTOM_AREAS).filter_map { |a| sanitize_custom_area(a) }
  rescue JSON::ParserError
    []
  end

  def sanitize_custom_area(a)
    return nil unless a.is_a?(Hash) || a.is_a?(ActionController::Parameters)
    h = a.respond_to?(:to_unsafe_h) ? a.to_unsafe_h : a.transform_keys(&:to_s)
    case h["type"]
    when "circle"
      lat = h.dig("center", "lat")&.to_f
      lng = h.dig("center", "lng")&.to_f
      rad = h["radius_m"]&.to_f
      return nil unless lat && lng && rad
      return nil unless lat.between?(-90, 90) && lng.between?(-180, 180)
      return nil unless rad.between?(MIN_CIRCLE_RADIUS_M, MAX_CIRCLE_RADIUS_M)
      {
        "id" => h["id"].to_s.presence || SecureRandom.uuid,
        "type" => "circle",
        "name" => h["name"].to_s.first(120).presence,
        "center" => { "lat" => lat, "lng" => lng },
        "radius_m" => rad
      }
    when "polygon"
      # Polygon support: drawing UI not yet shipped, but data path is in place.
      g = h["geojson"]
      return nil unless g.is_a?(Hash) && %w[Polygon MultiPolygon].include?(g["type"])
      return nil unless g["coordinates"].is_a?(Array)
      {
        "id" => h["id"].to_s.presence || SecureRandom.uuid,
        "type" => "polygon",
        "name" => h["name"].to_s.first(120).presence,
        "geojson" => g
      }
    end
  end

  # Background — see RematerializeFilteredSetsJob. Inline rematerialization was
  # blocking add_image / remove_item requests on Nominatim fetches.
  def refresh_filtered_children
    RematerializeFilteredSetsJob.perform_later(@image_set.id) if @image_set.filtered_sets.exists?
  end

  # === AI helpers ===

  # Per-user daily cap. With $0.01-0.05 per call on Flash, 20 calls/day
  # caps a single user at ~$1/day worst case. Persisted in postgres
  # (AiUsage) — earlier version stored counts in Rails.cache, but the
  # configured :memory_store is process-local, so multi-worker puma
  # counted separately per worker (effectively 2-4x the limit), and
  # dyno restarts wiped the count entirely.
  AI_DAILY_LIMIT = 20

  def ai_rate_limited?
    AiUsage.exceeded?(user: Current.user, daily_limit: AI_DAILY_LIMIT)
  end

  def bump_ai_rate_limit_counter
    AiUsage.bump!(user: Current.user)
  end

  # Parse the hidden conversation field. Bounded length so a giant
  # forged payload can't blow up the Gemini request.
  MAX_CONVERSATION_TURNS = 10

  def parse_conversation(raw)
    return [] if raw.blank?
    parsed = JSON.parse(raw)
    return [] unless parsed.is_a?(Array)
    parsed.first(MAX_CONVERSATION_TURNS).filter_map do |turn|
      next unless turn.is_a?(Hash)
      role = turn["role"]
      text = turn["text"].to_s
      next unless %w[user model].include?(role) && !text.empty?
      { role: role, text: text.first(8000) }
    end
  rescue JSON::ParserError
    []
  end

  # Look up the AiGeneration the view should render. Scoped to
  # current_user so a forged ?generation_id pointing at another user's
  # record degrades to "no generation" rather than leaking content.
  def load_ai_generation(id)
    return nil if id.blank?
    Current.user.ai_generations.find_by(id: id)
  end
end
