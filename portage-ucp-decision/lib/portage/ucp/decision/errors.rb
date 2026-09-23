module Portage
  module Ucp
    module Decision
      class Error < StandardError; end

      # Raised by a ModelBackend when it's asked to run without whatever it
      # needs to actually reach a model — an API key (Jev) or a local
      # inference command (Laya) — rather than failing further in with a
      # confusing HTTP or ENOENT error.
      class BackendNotConfiguredError < Error; end

      # Raised by a ModelBackend when the call itself fails — a non-2xx
      # response (Jev) or a non-zero exit status (Laya).
      class BackendError < Error; end

      # Raised by ModelBackends.resolve for a name not in ModelBackends::REGISTRY.
      class UnknownBackendError < Error; end
    end
  end
end
