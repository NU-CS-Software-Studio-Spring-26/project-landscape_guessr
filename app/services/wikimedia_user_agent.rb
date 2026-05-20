# Shared User-Agent string for every service that hits a Wikimedia
# property (Wikidata, Wikipedia, Commons). Wikimedia's API etiquette
# requires an identifying UA with contact info — duplicating the
# literal across 5 services was a maintenance hazard, so it lives
# here. RUBY_VERSION is captured at load time.
module WikimediaUserAgent
  STRING = "landscape-guessr/ai-image-sets (https://github.com/NU-CS-Software-Studio-Spring-26/project-landscape_guessr) Ruby/#{RUBY_VERSION}".freeze
end
