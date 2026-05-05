class ImageSetsController < ApplicationController
  before_action :set_image_set, only: %i[show edit update destroy locations update_locations add_image attach_blob processing_status remove_item map]
  before_action :require_owner, only: %i[edit update destroy locations update_locations add_image attach_blob processing_status remove_item]

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
  def show
    @items = @image_set.image_set_items.includes(:image).order("images.title")
  end

  # GET /image_sets/new
  def new
    @image_set = ImageSet.new(visibility: "private")
  end

  # POST /image_sets
  def create
    @image_set = Current.user.image_sets.new(image_set_params)
    if @image_set.save
      # Drop straight into the manage page — a freshly created set has no
      # images, so the natural next step is to upload some.
      redirect_to locations_image_set_path(@image_set), notice: "Set created — add some images to start."
    else
      render :new, status: :unprocessable_entity
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
    @items = @image_set.image_set_items.includes(image: { photo_attachment: :blob }).order(:id)
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
          unless item.image.update(title: new_title)
            errors << "#{item.title}: #{item.image.errors.full_messages.join(', ')}"
          end
        end
      end
      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      @items = @image_set.image_set_items.includes(:image).order(:id)
      flash.now[:alert] = errors.join("; ")
      render :locations, status: :unprocessable_entity
    else
      redirect_to locations_image_set_path(@image_set), notice: "Changes saved."
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
      redirect_to locations_image_set_path(@image_set), alert: "Please enter an image URL." and return
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
      redirect_to locations_image_set_path(@image_set), notice: "Image added to set."
    else
      redirect_to locations_image_set_path(@image_set), alert: "That image is already in this set."
    end
  end

  # DELETE /image_sets/1/items/123
  def remove_item
    item = @image_set.image_set_items.find_by(id: params[:item_id])
    if item
      item.destroy
      redirect_back fallback_location: @image_set, notice: "Image removed from set."
    else
      redirect_back fallback_location: @image_set, alert: "Image not found in this set."
    end
  end

  # GET /image_sets/1/map
  def map
    items = @image_set.image_set_items.includes(image: { photo_attachment: :blob })
    @image_data = items.filter_map do |item|
      lat = item.latitude || item.image.latitude
      lng = item.longitude || item.image.longitude
      next unless lat && lng
      img = item.image
      display_url = if img.photo.attached?
        url_for(img.photo)
      elsif img.url.present?
        img.url
      end
      { id: img.id, lat: lat.to_f, lng: lng.to_f, title: item.title, url: display_url }
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
    unless @image_set.owned_by?(Current.user)
      redirect_to @image_set, alert: "You don't have permission to edit this set."
    end
  end

  def image_set_params
    params.expect(image_set: [ :name, :visibility ])
  end
end
