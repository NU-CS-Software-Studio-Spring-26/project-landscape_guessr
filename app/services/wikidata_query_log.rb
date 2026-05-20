require "logger"

# Dedicated log for outbound Wikidata + Wikipedia HTTP traffic. Keeps
# query bodies, durations, HTTP status, and result sizes in one
# greppable place — easier to diagnose "why was that import slow / why
# did it fail" without sifting Rails' main log.
#
# Output lives at log/wikidata.log. Rotated at 5 MB × 10 files so it
# can't grow unbounded in long-lived dev / prod processes.
#
# Format (tab-separated, one line per call):
#   ISO8601_UTC  SEVERITY  ACTION  STATUS  DUR  key=val  key=val ...
#
# Example:
#   2026-05-15T22:10:00Z  INFO   sparql       200  3.45s  bindings=1247  q="SELECT DISTINCT…"
#   2026-05-15T22:10:13Z  ERROR  sparql       502  19.0s  attempt=1  error="<html>…"
#   2026-05-15T22:10:14Z  INFO   sparql       200  4.20s  attempt=2  bindings=1247
#   2026-05-15T22:10:30Z  INFO   wbsearch     200  0.12s  q="volcano"  hits=10
module WikidataQueryLog
  PATH    = "log/wikidata.log".freeze
  MAX_LOG = 5 * 1024 * 1024 # 5 MB per file
  KEEP    = 10              # keep 10 rotations

  # ActiveSupport::Logger because that's what Rails uses elsewhere (it
  # tags severity colors in TTY); but ordinary Logger would work too.
  LOGGER = begin
    path = defined?(Rails) ? Rails.root.join(PATH) : PATH
    logger = ActiveSupport::Logger.new(path, KEEP, MAX_LOG)
    logger.formatter = lambda do |severity, time, _progname, msg|
      "#{time.utc.iso8601}\t#{severity.ljust(5)}\t#{msg}\n"
    end
    logger
  end

  # `status` is the HTTP code as a string ("200", "502") or a sentinel
  # ("timeout", "exception"). 4xx/5xx + sentinels get logged as ERROR;
  # everything else as INFO. `details` is arbitrary key/value metadata
  # (bindings count, batch size, retry attempt, etc.).
  def self.log(action:, status:, duration:, **details)
    fields = [
      action.to_s.ljust(11),
      status.to_s.ljust(8),
      "#{duration.to_f.round(2)}s"
    ]
    details.each do |k, v|
      next if v.nil?
      val = v.is_a?(String) ? v.inspect : v
      fields << "#{k}=#{val}"
    end
    error_status = status.to_s =~ /\A([45]\d\d|timeout|exception)\z/
    LOGGER.public_send(error_status ? :error : :info, fields.join("\t"))
  rescue StandardError => e
    # Logger failures must never break the actual operation. Swallow.
    Rails.logger.warn "[WikidataQueryLog] #{e.class}: #{e.message}" if defined?(Rails)
  end

  # Collapses a SPARQL query to a single line so each log entry stays
  # one row (greppable). NO truncation — the whole point of this log is
  # so the user can copy/paste a failing query straight from the file.
  # SPARQL queries are typically <2 KB so this doesn't bloat much; the
  # rotation cap (50 MB total) absorbs the rest.
  def self.summarize_sparql(sparql)
    sparql.to_s.gsub(/\s+/, " ").strip
  end
end
