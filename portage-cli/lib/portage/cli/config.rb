require "json"
require "fileutils"

module Portage
  module Cli
    # Durable, editable `portage-cli` config — `~/.portage/config.json` — for
    # standing preferences that aren't payment/policy specific (the auto-open
    # and notify-webhook toggles in docs/plans/checkout-handoff-delivery.md
    # are the first two keys). Same shape as Portage::Ucp::Policy: absent
    # file or absent key means "unset", a corrupt file raises rather than
    # silently falling back.
    class Config
      PATH = File.join(Dir.home, ".portage", "config.json").freeze

      def self.load(path: PATH) = new(path: path, data: read(path))

      def initialize(path: PATH, data: {})
        @path = path
        @data = data
      end

      def get(key) = @data[key.to_s]

      def set(key, value)
        @data[key.to_s] = value
        write
        value
      end

      def to_h = @data.dup

      def self.read(path)
        return {} unless File.readable?(path)

        raw = File.read(path)
        return {} if raw.empty?

        parsed = JSON.parse(raw)
        parsed.is_a?(Hash) ? parsed : {}
      end
      private_class_method :read

      private

      def write
        FileUtils.mkdir_p(File.dirname(@path))
        File.write(@path, JSON.pretty_generate(@data))
        File.chmod(0o600, @path)
      end
    end
  end
end
