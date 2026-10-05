require "net/http"
require "uri"
require "json"
require "fileutils"
require "timeout"
require "portage/ucp/support/connection"

require_relative "../user_agent"

module Portage
  module Cli
    module Index
      # The repo's own `known-stores/{stores,products}.json`, fetched over
      # jsdelivr `@main` and cached at `~/.portage/index/known-{stores,
      # products}.json` (docs/plans/buy-skill-and-local-browser.md Phase
      # 2c). Same untrusted-data posture as Store/ProductStore — see their
      # own comments at the top of this directory — plus one more rule:
      # the user's own entries always win, so SearchBackends::Index merges
      # this cache *underneath* Store/ProductStore rather than the other
      # way round; this class never writes into Store/ProductStore itself.
      #
      # Fetched lazily the first time a caller needs it and no cache file
      # exists yet (SearchBackends::Index#available?/#search), refreshed
      # unconditionally by `portage index refresh`, and refreshed by
      # `doctor` when it finds the cache older than STALE_AFTER. A fetch
      # failure — offline, timeout, bad JSON, a non-2xx response — is
      # swallowed exactly like SearchBackends/OfferSources::ShopifyCatalog:
      # a stale or missing cache just means `find` works the way it did
      # before this phase.
      class KnownCache
        STORES_PATH = File.join(Dir.home, ".portage", "index", "known-stores.json").freeze
        PRODUCTS_PATH = File.join(Dir.home, ".portage", "index", "known-products.json").freeze

        # Published on the same jsdelivr `@main` channel AgentProfileUrl
        # uses for the agent profile: free GitHub, no Actions, so a new
        # entry reaches every install on its next refresh as soon as a PR
        # merges, with no gem/brew release to wait on.
        BASE_URL = "https://cdn.jsdelivr.net/gh/tomtom87/Portage@main/portage-cli/known-stores".freeze
        STORES_URL = "#{BASE_URL}/stores.json".freeze
        PRODUCTS_URL = "#{BASE_URL}/products.json".freeze

        STALE_AFTER = 7 * 24 * 60 * 60
        TIMEOUT = 5

        # No known-stores/products entry may carry a price or stock field
        # — Store/ProductStore's own comment says those are always live,
        # and a fetched file is one more untrusted input than a locally
        # built one, so this is checked again on the way in rather than
        # trusting the source repo's own review (there's no CI gate for
        # it — Decision 1a, "no central artifact, so no signing").
        FORBIDDEN_FIELDS = %w[price amount stock].freeze

        def initialize(stores_path: STORES_PATH, products_path: PRODUCTS_PATH,
                       stores_url: STORES_URL, products_url: PRODUCTS_URL)
          @stores_path = stores_path
          @products_path = products_path
          @stores_url = stores_url
          @products_url = products_url
        end

        # @return [Hash] origin => entry, same schema as Index::Store's own
        #   file.
        def stores = read(@stores_path)

        # @return [Hash] key => entry, same schema as Index::ProductStore's
        #   own file.
        def products = read(@products_path)

        def exists? = File.exist?(@stores_path) || File.exist?(@products_path)

        # @return [Integer, nil] seconds since the stores cache was last
        #   fetched — its own file mtime, since the cache is written in the
        #   same schema as the local index and carries no fetch timestamp
        #   of its own. nil when there's no cache yet.
        def age(now: Time.now)
          return nil unless File.exist?(@stores_path)

          now.to_i - File.mtime(@stores_path).to_i
        end

        def stale?(now: Time.now)
          a = age(now: now)
          a.nil? || a > STALE_AFTER
        end

        # The "first run" trigger: only fetches when there's no cache file
        # at all — a stale-but-present cache is left for `index
        # refresh`/`doctor` to decide about, not silently re-fetched on
        # every `find`.
        # @return [Boolean] whether a fetch happened (and its outcome).
        def fetch_if_missing!
          return false if exists?

          refresh!
        end

        # `index refresh` and a stale `doctor` check call this
        # unconditionally.
        # @return [Boolean] true when at least one of the two files
        #   fetched successfully.
        def refresh!
          stores_ok = fetch_and_cache(@stores_url, @stores_path)
          products_ok = fetch_and_cache(@products_url, @products_path)
          stores_ok || products_ok
        end

        private

        def fetch_and_cache(url, path)
          data = Timeout.timeout(TIMEOUT) { fetch(url) }
          return false unless valid?(data)

          write(path, sanitize(data))
          true
        rescue StandardError
          false
        end

        def fetch(url)
          uri = URI.parse(url)
          response = Portage::Ucp::Support::Connection.start(
            uri, route: :search, open_timeout: TIMEOUT, read_timeout: TIMEOUT
          ) { |http| http.get(uri.request_uri, UserAgent.headers) }
          return nil unless response.is_a?(Net::HTTPSuccess)

          JSON.parse(response.body)
        end

        # Same shape as Store/ProductStore's own file: a Hash keyed by
        # origin (stores) or product key (products), each value itself a
        # Hash. Anything else — an array, a string, a top-level list — is a
        # fetch gone wrong, not a cache worth keeping.
        def valid?(data)
          data.is_a?(Hash) && data.values.all?(Hash)
        end

        def sanitize(data)
          data.transform_values { |entry| entry.reject { |k, _| FORBIDDEN_FIELDS.include?(k.to_s) } }
        end

        # A cache that can't be written just means this fetch's findings
        # aren't saved — never a crash (same posture as Store/
        # ProductStore#write).
        def write(path, data)
          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, JSON.generate(data))
        rescue StandardError
          nil
        end

        def read(path)
          return {} unless File.readable?(path)

          parsed = JSON.parse(File.read(path, encoding: "UTF-8"))
          parsed.is_a?(Hash) ? parsed : {}
        rescue StandardError
          {}
        end
      end
    end
  end
end
