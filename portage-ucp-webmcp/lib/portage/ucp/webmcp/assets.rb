require "json"

module Portage
  module Ucp
    module WebMcp
      # The browser-side halves of this gem live as plain `.js` files next to
      # this one (lib/portage/ucp/webmcp/assets/) rather than as Ruby heredocs,
      # so they can be linted, diffed and run under node in the specs exactly
      # as a browser receives them.
      module Assets
        DIR = File.expand_path("assets", __dir__)

        # Read as UTF-8 explicitly: the scripts contain non-ASCII, and with no
        # LANG set Ruby defaults to US-ASCII, so anything that JSON-encodes
        # the source (a browser driver's evaluate call) raised on it.
        def self.read(name)
          @cache ||= {}
          @cache[name] ||= File.read(File.join(DIR, name), encoding: "UTF-8").freeze
        end

        # JSON safe to drop into an inline `<script>` body as well as a served
        # `.js` file: `</script>` can't close the tag early, and U+2028/U+2029
        # (legal in JSON, line terminators in pre-ES2019 JavaScript) are
        # escaped.
        def self.inline_json(value)
          JSON.generate(value).gsub("</", "<\\/").gsub("\u2028", "\\u2028").gsub("\u2029", "\\u2029")
        end
      end
    end
  end
end
