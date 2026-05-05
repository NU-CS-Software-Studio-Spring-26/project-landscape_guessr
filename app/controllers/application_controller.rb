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
end
