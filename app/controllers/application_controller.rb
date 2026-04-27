class ApplicationController < ActionController::Base
  include Authentication
  # Only allow modern browsers supporting webp images, web push, badges, import maps, CSS nesting, and CSS :has.
  allow_browser versions: :modern

  # Changes to the importmap will invalidate the etag for HTML responses
  stale_when_importmap_changes

  helper_method :admin?

  private
    def admin?
      authenticated? && Current.user.admin?
    end

    def require_admin
      redirect_to root_path, alert: "Admin access required." unless admin?
    end
end
