module Portage
  module Ucp
    # Registers `rails g portage:ucp:install` with a host Rails app. Only
    # loaded when Rails is already present (see the guarded require at the
    # bottom of ucp.rb) — this gem has no Rails dependency of its own (it's
    # the protocol-only core, per the gemspec), so Rails integration is
    # opt-in via whatever the host app already bundles.
    class Railtie < ::Rails::Railtie
      generators do
        require "generators/portage/ucp/install/install_generator"
      end
    end
  end
end
