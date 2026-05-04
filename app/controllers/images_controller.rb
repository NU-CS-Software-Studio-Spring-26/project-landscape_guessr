class ImagesController < ApplicationController
  allow_unauthenticated_access only: %i[ index show map ]
  before_action :require_admin, only: %i[ new create edit update destroy ]
  before_action :set_image, only: %i[ show edit update destroy ]

  # GET /images or /images.json
  def index
    @images = Image.all
  end

  # GET /images/map
  def map
    images = Image.with_attached_photo.all
    @image_data = images.map do |img|
      display_url = if img.photo.attached?
        url_for(img.photo)
      elsif img.url.present?
        img.url
      end
      { id: img.id, lat: img.latitude.to_f, lng: img.longitude.to_f, title: img.title, url: display_url }
    end
  end

  # GET /images/1 or /images/1.json
  def show
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

    # Only allow a list of trusted parameters through.
    def image_params
      params.expect(image: [ :url, :latitude, :longitude, :title ])
    end
end
