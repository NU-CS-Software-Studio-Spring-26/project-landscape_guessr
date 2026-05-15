class ImagesController < ApplicationController
  allow_unauthenticated_access only: %i[ index show map ]
  before_action :require_admin,    only: %i[ new create destroy ]
  before_action :set_image,        only: %i[ show edit update destroy ]
  before_action :require_editable, only: %i[ edit update ]

  # GET /images or /images.json
  def index
    @images = paginate(
      (admin? ? Image.all : Image.visible_to(Current.user)).with_attached_photo.order(:id),
      per_page: 100
    )
  end

  # GET /images/map
  def map
    images = (admin? ? Image.all : Image.visible_to(Current.user)).with_attached_photo
    @image_data = images.map do |img|
      { id: img.id, lat: img.latitude.to_f, lng: img.longitude.to_f, title: img.title, url: view_context.image_src(img) }
    end
  end

  # GET /images/1 or /images/1.json
  def show
    unless admin? || @image.visible_to?(Current.user)
      redirect_to images_path, alert: "That image is private." and return
    end

    # Set memberships visible to the current viewer, ordered alphabetically.
    # Used by the detail page's "In sets" panel and to surface a per-set
    # "Remove from this set" button on sets the user owns.
    @memberships = @image.image_sets
                         .merge(visible_image_sets)
                         .order(:name)
                         .preload(:user)
    @items_by_set_id = @image.image_set_items.index_by(&:image_set_id)
  end

  # GET /images/new
  def new
    @image = Image.new
  end

  # GET /images/1/edit
  def edit
  end

  # POST /images or /images.json
  def create
    @image = Image.new(image_params)

    respond_to do |format|
      if @image.save
        default_set = ImageSet.default
        if default_set
          default_set.image_set_items.find_or_create_by!(image: @image) do |item|
            item.latitude  = @image.latitude
            item.longitude = @image.longitude
          end
        end
        format.html { redirect_to @image, notice: "Image was successfully created." }
        format.json { render :show, status: :created, location: @image }
      else
        format.html { render :new, status: :unprocessable_entity }
        format.json { render json: @image.errors, status: :unprocessable_entity }
      end
    end
  end

  # PATCH/PUT /images/1 or /images/1.json
  def update
    respond_to do |format|
      if @image.update(image_params)
        format.html { redirect_to @image, notice: "Image was successfully updated.", status: :see_other }
        format.json { render :show, status: :ok, location: @image }
      else
        format.html { render :edit, status: :unprocessable_entity }
        format.json { render json: @image.errors, status: :unprocessable_entity }
      end
    end
  end

  # DELETE /images/1 or /images/1.json
  def destroy
    @image.destroy!

    respond_to do |format|
      format.html { redirect_to images_path, notice: "Image was successfully destroyed.", status: :see_other }
      format.json { head :no_content }
    end
  end

  private
    # Use callbacks to share common setup or constraints between actions.
    def set_image
      @image = Image.find(params.expect(:id))
    end

    # Only allow a list of trusted parameters through. The :url field is
    # admin-only — once an image exists, swapping its underlying URL out
    # from under set members would silently change every game that's
    # already played that image. Title and coords are safe to edit.
    def image_params
      permitted = [ :latitude, :longitude, :title ]
      permitted << :url if admin?
      params.expect(image: permitted)
    end

    # 403 unless the current user owns at least one set containing this
    # image (or is admin). See Image#editable_by? for the rationale.
    def require_editable
      return if @image.editable_by?(Current.user)
      redirect_to @image, alert: "You don't have permission to edit this image."
    end

    # Sets the current viewer is allowed to see. Admin bypasses the scope.
    def visible_image_sets
      admin? ? ImageSet.all : ImageSet.visible_to(Current.user)
    end
end
