require "active_support/core_ext/integer/time"

Rails.application.configure do
  # Settings specified here will take precedence over those in config/application.rb.

  # Code is not reloaded between requests.
  config.enable_reloading = false

  # Eager load code on boot for better performance and memory savings (ignored by Rake tasks).
  config.eager_load = true

  # Full error reports are disabled.
  config.consider_all_requests_local = false

  # Turn on fragment caching in view templates.
  config.action_controller.perform_caching = true

  # Cache assets for far-future expiry since they are all digest stamped.
  config.public_file_server.headers = { "cache-control" => "public, max-age=#{1.year.to_i}" }

  # Enable serving of images, stylesheets, and JavaScripts from an asset server.
  # config.asset_host = "http://assets.example.com"

  # Store uploaded files on the local file system (see config/storage.yml for options).
  config.active_storage.service = :amazon

  # Skip Active Storage's content analyzers. They re-download each blob
  # from S3 and decode it via vips just to extract width/height into
  # blob.metadata, which we don't read anywhere. On Heroku Basic (512MB)
  # the per-blob decode pile-up after a bulk upload is enough to OOM the
  # web dyno. With analyzers=[] the AnalyzeJob falls back to NullAnalyzer:
  # the job still runs but does no download and no decode, just marks the
  # blob as analyzed.
  config.active_storage.analyzers = []

  # Assume all access to the app is happening through a SSL-terminating reverse proxy.
  # config.assume_ssl = true

  # Force all access to the app over SSL, use Strict-Transport-Security, and use secure cookies.
  # config.force_ssl = true

  # Skip http-to-https redirect for the default health check endpoint.
  # config.ssl_options = { redirect: { exclude: ->(request) { request.path == "/up" } } }

  # Log to STDOUT with the current request id as a default log tag.
  config.log_tags = [ :request_id ]
  config.logger   = ActiveSupport::TaggedLogging.logger(STDOUT)

  # Change to "debug" to log everything (including potentially personally-identifiable information!).
  config.log_level = ENV.fetch("RAILS_LOG_LEVEL", "info")

  # Prevent health checks from clogging up the logs.
  config.silence_healthcheck_path = "/up"

  # Don't log any deprecations.
  config.active_support.report_deprecations = false

  # Use in-memory cache (no separate cache database needed).
  config.cache_store = :memory_store

  # Use async queue adapter (no separate queue database needed). max_threads
  # is capped to 1 because Concurrent.processor_count returns the underlying
  # Heroku host's core count (often 8) — the default would let 8
  # ProcessImageJobs decode HEICs concurrently, which OOMs a 512MB Basic
  # dyno even with vips cache disabled. Override via ENV for dev or larger
  # plans where parallel processing is fine.
  config.active_job.queue_adapter = ActiveJob::QueueAdapters::AsyncAdapter.new(
    min_threads:     0,
    max_threads:     ENV.fetch("ACTIVE_JOB_ASYNC_MAX_THREADS", "1").to_i,
    idletime:        60,
    max_queue:       0,
    fallback_policy: :caller_runs
  )

  # Ignore bad email addresses and do not raise email delivery errors.
  # Set this to true and configure the email server for immediate delivery to raise delivery errors.
  # config.action_mailer.raise_delivery_errors = false

  # Set host to be used by links generated in mailer templates.
  config.action_mailer.default_url_options = { host: "landscape-guessr-cc7bc949a622.herokuapp.com", protocol: "https" }

  config.action_mailer.delivery_method = :smtp
  config.action_mailer.raise_delivery_errors = true
  config.action_mailer.smtp_settings = {
    address:         "smtp.gmail.com",
    port:            587,
    user_name:       ENV["GMAIL_USERNAME"],
    password:        ENV["GMAIL_APP_PASSWORD"],
    authentication:  :plain,
    enable_starttls: true
  }

  # Enable locale fallbacks for I18n (makes lookups for any locale fall back to
  # the I18n.default_locale when a translation cannot be found).
  config.i18n.fallbacks = true

  # Do not dump schema after migrations.
  config.active_record.dump_schema_after_migration = false

  # Only use :id for inspections in production.
  config.active_record.attributes_for_inspect = [ :id ]

  # Enable DNS rebinding protection and other `Host` header attacks.
  # config.hosts = [
  #   "example.com",     # Allow requests from example.com
  #   /.*\.example\.com/ # Allow requests from subdomains like `www.example.com`
  # ]
  #
  # Skip DNS rebinding protection for the default health check endpoint.
  # config.host_authorization = { exclude: ->(request) { request.path == "/up" } }
end
