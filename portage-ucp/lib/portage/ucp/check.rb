require "net/http"
require "uri"
require "json"

module Portage
  module Ucp
    # `portage-ucp-check <url>` — point it at any storefront and find out what
    # portage-ucp can do with it. Checks for a native `/.well-known/ucp`
    # manifest first (the store may already speak UCP without this gem, see
    # README's "Why /.well-known/ucp?"); if there isn't one, detects the
    # commerce platform from the page itself (see Resolver) and names
    # the matching portage-ucp-<adapter> gem — probing it live when that
    # adapter's env vars are already set, so "best match" means a
    # confirmed-working adapter, not just a guess.
    class Check
      MANIFEST_PATH = "/.well-known/ucp".freeze
      REDIRECT_LIMIT = 5

      def self.call(url) = new(url).call

      def initialize(url)
        raw = url.to_s.strip
        raw = "https://#{raw}" unless raw =~ %r{\Ahttps?://}i
        @uri = URI.parse(raw)
      end

      def call
        manifest = fetch_manifest
        return { url: @uri.to_s, native_ucp: manifest } if manifest

        body, headers = fetch_homepage
        platform = Resolver.detect_platform(body, headers)

        report = { url: @uri.to_s, native_ucp: nil, platform: platform&.name, recommended_gem: platform&.gem }
        report[:live_probe] = probe(platform) if platform
        report
      end

      private

      def fetch_manifest
        manifest_uri = @uri.dup
        manifest_uri.path = MANIFEST_PATH
        response = get(manifest_uri)
        return nil unless response.is_a?(Net::HTTPSuccess)

        JSON.parse(response.body)
      rescue StandardError
        nil
      end

      def fetch_homepage
        response = get(@uri)
        return [nil, {}] unless response.is_a?(Net::HTTPSuccess)

        [response.body, response.to_hash]
      rescue StandardError
        [nil, {}]
      end

      def probe(platform)
        env = Resolver.env_for(platform)
        missing = Resolver.missing_env(platform, env)
        return { status: "skipped", reason: "missing env vars: #{missing.join(', ')}" } if missing.any?

        run_probe(platform, env)
      end

      def run_probe(platform, env)
        adapter = Resolver.build_adapter(platform, env)
        product = adapter.search_catalog(query: "", limit: 1)&.first
        { status: "ok", sample_product: product && { id: product.id, title: product.title } }
      rescue LoadError
        { status: "skipped", reason: "gem not installed: #{platform.gem}" }
      rescue StandardError => e
        { status: "error", reason: "#{e.class}: #{e.message}" }
      end

      def get(uri, limit = REDIRECT_LIMIT)
        raise Portage::Ucp::Error, "too many redirects" if limit.zero?

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https",
                                                       open_timeout: 5, read_timeout: 5) do |http|
          http.get(uri.request_uri, { "User-Agent" => "portage-ucp-check" })
        end

        case response
        when Net::HTTPRedirection
          get(URI.join(uri, response["location"]), limit - 1)
        else
          response
        end
      end
    end
  end
end
