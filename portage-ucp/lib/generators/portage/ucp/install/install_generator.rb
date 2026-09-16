require "rails/generators"

module Portage
  module Ucp
    module Generators
      # rails g portage:ucp:install — writes the initializer stub and mounts
      # the discovery/webhook Rack endpoints. Leaves authenticator, rate
      # limiter and business identity as TODOs: none of those have a safe
      # default a generator could pick for the host app (see
      # UnconfiguredAuthenticator/NullRateLimiter in configuration.rb).
      class InstallGenerator < ::Rails::Generators::Base
        source_root File.expand_path("templates", __dir__)

        def copy_initializer
          template "portage_ucp.rb", "config/initializers/portage_ucp.rb"
        end

        def add_routes
          route <<~RUBY.strip
            # TODO: replace YOUR_ADAPTER with your Portage::Ucp::Adapter instance.
            mount Portage::Ucp::Rack::ManifestEndpoint.new(manifest: Portage::Ucp::Manifest.new(adapter: YOUR_ADAPTER)) => "/.well-known/ucp"
            mount Portage::Ucp::Rack::WebhookEndpoint.new(secret: Rails.application.credentials.dig(:portage_ucp, :webhook_secret), on_order_event: ->(order) { }) => "/webhooks/portage_ucp"
          RUBY
        end
      end
    end
  end
end
