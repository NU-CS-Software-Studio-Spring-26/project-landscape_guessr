class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  # Hitting a stale link / typo'd id (/games/9999, /image_sets/foo) raises
  # RecordNotFound which Rails would otherwise render with a stack trace
  # in dev and a bare /404.html in prod. Redirect somewhere sensible with a
  # flash so the user lands on a real page.
  rescue_from ActiveRecord::RecordNotFound, with: :render_not_found

  helper_method :admin?

  PER_PAGE_OPTIONS = [ 25, 50, 100, 250, 500 ].freeze

  private
    def admin?
      authenticated? && Current.user.admin?
    end

    def require_admin
      redirect_to root_path, alert: "Admin access required." unless admin?
    end

    def render_not_found
      respond_to do |format|
        format.html { redirect_back fallback_location: root_path, alert: "We couldn't find what you were looking for." }
        format.json { head :not_found }
      end
    end

    # Slice a relation into a page based on params[:page]. Used by image
    # galleries (image_sets#show, image_sets#locations, images#index) and
    # the games index to cap DOM load on long lists. Returns the windowed
    # relation; sets @page / @total_pages / @total_items / @per_page on
    # the controller for the view to render the shared _pagination partial.
    #
    # `per_page:` is the *default* — if ?per_page= is in the allowed list
    # (PER_PAGE_OPTIONS) the user override wins. ?page= is clamped to
    # [1, total_pages] so users fiddling the URL never land on an empty
    # page or a negative offset.
    def paginate(scope, per_page:)
      requested = params[:per_page].to_i
      per_page  = requested if PER_PAGE_OPTIONS.include?(requested)
      total = scope.size
      pages = [ (total.to_f / per_page).ceil, 1 ].max
      page  = params[:page].to_i.clamp(1, pages)
      @page        = page
      @total_pages = pages
      @total_items = total
      @per_page    = per_page
      scope.offset((page - 1) * per_page).limit(per_page)
    end
end
