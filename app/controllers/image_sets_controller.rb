class ImageSetsController < ApplicationController
  before_action :set_image_set, only: %i[show edit update destroy locations update_locations add_image bulk_upload remove_item]
  before_action :require_owner, only: %i[edit update destroy locations update_locations add_image bulk_upload remove_item]

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
      redirect_to @image_set, notice: "Image set created."
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
    @items = @image_set.image_set_items.includes(image: { photo_attachment: :blob }).order("images.title")
    @processing_count = @items.count { |i| !i.image.processed? }
  end

  # PUT /image_sets/1/locations
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
      end
      raise ActiveRecord::Rollback if errors.any?
    end

    if errors.any?
      @items = @image_set.image_set_items.includes(:image).order("images.title")
      flash.now[:alert] = errors.join("; ")
      render :locations, status: :unprocessable_entity
    else
      redirect_to locations_image_set_path(@image_set), notice: "Locations saved."
    end
  end

  # POST /image_sets/1/add_image
  def add_image
    file  = params[:file]
    url   = params[:url].to_s.strip
    title = params[:title].to_s.strip.presence
    lat   = params[:latitude].presence&.to_f
    lng   = params[:longitude].presence&.to_f

    if file.present?
      title ||= File.basename(file.original_filename, ".*").gsub(/[_-]+/, " ").titleize
      # Read EXIF GPS *before* the JPEG re-encode strips metadata.
      if lat.nil? && lng.nil? && (gps = Image.gps_from_upload(file))
        lat, lng = gps
      end
      image = Image.create!(title: title, latitude: lat, longitude: lng)
      image.photo.attach(Image.process_upload(file))
    elsif url.present?
      title ||= "Untitled"
      image = Image.find_or_create_by!(url: url) do |img|
        img.title     = title
        img.latitude  = lat
        img.longitude = lng
      end
    else
      redirect_to locations_image_set_path(@image_set), alert: "Please upload a file or enter a URL." and return
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

  # POST /image_sets/1/bulk_upload
  #
  # Direct-upload flow: the browser PUTs each original (HEIC/JPEG/...)
  # straight to S3 via Active Storage's direct_upload, then submits this
  # form with an array of blob signed_ids in params[:files]. This action
  # is now I/O-trivial: it just attaches each blob to a new Image and
  # enqueues a ProcessImageJob to do the libvips work in the background.
  # Heroku web dyno never sees the original bytes -> no R14, no H12.
  def bulk_upload
    signed_ids = Array(params[:files]).map(&:to_s).reject(&:empty?)

    if signed_ids.empty?
      redirect_to locations_image_set_path(@image_set), alert: "No files selected." and return
    end

    added = 0
    errors = []

    signed_ids.each do |signed_id|
      blob = ActiveStorage::Blob.find_signed(signed_id)
      next unless blob

      title = File.basename(blob.filename.to_s, ".*").gsub(/[_-]+/, " ").titleize
      image = Image.create!(title: title)
      image.photo.attach(blob)

      item = @image_set.image_set_items.find_or_initialize_by(image: image)
      if item.new_record?
        item.save!
        added += 1
      end

      ProcessImageJob.perform_later(image)
    rescue => e
      errors << "#{blob&.filename || signed_id}: #{e.message}"
    end

    msg = "#{added} image(s) queued. Thumbnails and EXIF coordinates will appear as background processing finishes — refresh in a minute."
    if errors.any?
      redirect_to locations_image_set_path(@image_set), alert: "#{msg} Errors: #{errors.join('; ')}"
    else
      redirect_to locations_image_set_path(@image_set), notice: msg
    end
  end

  private

  def set_image_set
    @image_set = ImageSet.find(params[:id])
    # Allow reading public/system sets; editing is guarded by require_owner
    unless @image_set.is_system_default? || @image_set.owned_by?(Current.user) || @image_set.visibility == "public"
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
