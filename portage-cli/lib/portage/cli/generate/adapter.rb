require "fileutils"
require "portage/ucp"

module Portage
  module Cli
    module Generate
      # `portage generate adapter Foo` — scaffolds a new adapter gem shaped
      # like the bundled ones (portage-ucp-etsy is the template this follows
      # most closely: gemspec depending on portage-ucp, Adapter subclass,
      # conformance spec). Every capability method is stubbed as `= super`,
      # reflected straight off Portage::Ucp::Adapter's own signatures rather
      # than hand-copied, so the scaffold can't drift from the real contract
      # the way a hardcoded template would the next time the contract grows.
      class Adapter
        def initialize(name:, dir: nil)
          @module_name = camelize(name)
          @slug = underscore(name)
          @dir = dir || "portage-ucp-#{@slug}"
        end

        def call
          FileUtils.mkdir_p(File.join(@dir, "lib", "portage", "ucp", @slug))
          FileUtils.mkdir_p(File.join(@dir, "spec", "portage", "ucp", @slug))
          write_gemspec
          write_gemfile
          write_rakefile
          write_rubocop
          write_lib_entrypoint
          write_version
          write_adapter
          write_spec_helper
          write_conformance_spec
          @dir
        end

        private

        def camelize(str) = str.to_s.split(/[_-]/).map { |w| w[0].upcase + w[1..] }.join
        def underscore(str) = str.to_s.gsub(/([a-z\d])([A-Z])/, '\1_\2').tr("-", "_").downcase

        def write(relative_path, content)
          File.write(File.join(@dir, relative_path), content)
        end

        def write_gemspec
          write "#{@dir}.gemspec", <<~RUBY
            require_relative "lib/portage/ucp/#{@slug}/version"

            Gem::Specification.new do |spec|
              spec.name = "portage-ucp-#{@slug}"
              spec.version = Portage::Ucp::#{@module_name}::VERSION
              spec.summary = "#{@module_name} adapter for portage-ucp"
              spec.description = "Implements Portage::Ucp::Adapter against #{@module_name}'s API. " \\
                                 "Generic only — no merchant-specific business logic."
              spec.authors = ["Tom Whitbread"]
              spec.license = "MIT"
              spec.homepage = "https://github.com/tomtom87/Portage/tree/main/#{@dir}"
              spec.required_ruby_version = ">= 3.2"

              spec.files = Dir["lib/**/*.rb", "README.md", "LICENSE", "CHANGELOG.md"]
              spec.require_paths = ["lib"]

              spec.add_dependency "portage-ucp", "~> 0.6"

              spec.add_development_dependency "rspec", "~> 3.13"
              spec.add_development_dependency "rubocop", "~> 1.88"
              spec.add_development_dependency "webmock", "~> 3.24"
              spec.metadata["source_code_uri"] = "https://github.com/tomtom87/Portage/tree/main/#{@dir}"
              spec.metadata["rubygems_mfa_required"] = "true"
            end
          RUBY
        end

        def write_gemfile
          write "Gemfile", <<~RUBY
            source "https://rubygems.org"

            gemspec

            gem "portage-ucp", path: "../portage-ucp"
          RUBY
        end

        def write_rakefile
          write "Rakefile", <<~RUBY
            require "bundler/gem_tasks"
            require "rspec/core/rake_task"

            RSpec::Core::RakeTask.new(:spec)

            task default: :spec
          RUBY
        end

        def write_rubocop
          write ".rubocop.yml", <<~YAML
            AllCops:
              NewCops: enable
              TargetRubyVersion: 3.2
              SuggestExtensions: false

            Style/FrozenStringLiteralComment:
              Enabled: false

            Style/StringLiterals:
              EnforcedStyle: double_quotes

            Style/Documentation:
              Enabled: false

            Metrics/BlockLength:
              Exclude:
                - "spec/**/*.rb"
                - "*.gemspec"

            # The scaffolded Adapter subclass is all `= super` stubs until
            # each one is replaced with a real implementation — rubocop
            # would otherwise flag every one of them as a useless override.
            Lint/UselessMethodDefinition:
              Exclude:
                - "lib/**/adapter.rb"

            Gemspec/DevelopmentDependencies:
              Enabled: false

            Gemspec/RequireMFA:
              Enabled: false
          YAML
        end

        def write_lib_entrypoint
          write "lib/portage/ucp/#{@slug}.rb", <<~RUBY
            require "portage/ucp"
            require_relative "#{@slug}/version"
            require_relative "#{@slug}/adapter"
          RUBY
        end

        def write_version
          write "lib/portage/ucp/#{@slug}/version.rb", <<~RUBY
            module Portage
              module Ucp
                module #{@module_name}
                  VERSION = "0.1.0".freeze
                end
              end
            end
          RUBY
        end

        def write_adapter
          write "lib/portage/ucp/#{@slug}/adapter.rb", <<~RUBY
            module Portage
              module Ucp
                module #{@module_name}
                  # TODO: fill in a real client/constructor, then replace each
                  # `= super` stub below with a real implementation. Leave a
                  # method as `= super` to leave that capability unadvertised
                  # (Portage::Ucp::Capability#advertised_for? — see adapter.rb).
                  class Adapter < Portage::Ucp::Adapter
            #{adapter_method_stubs}
                  end
                end
              end
            end
          RUBY
        end

        # One `= super` stub per public method Portage::Ucp::Adapter itself
        # defines, with the same keyword signature — reflected via
        # Method#parameters rather than hardcoded so this never drifts from
        # the contract's actual shape.
        def adapter_method_stubs
          Portage::Ucp::Adapter.instance_methods(false).sort.filter_map do |name|
            next if name.to_s.end_with?("_supported?")

            params = Portage::Ucp::Adapter.instance_method(name).parameters
            "        def #{name}(#{signature(params)}) = super"
          end.join("\n")
        end

        def signature(params)
          params.map do |type, param_name|
            case type
            when :keyreq then "#{param_name}:"
            when :key then "#{param_name}: nil"
            end
          end.compact.join(", ")
        end

        def write_spec_helper
          write "spec/spec_helper.rb", <<~RUBY
            require "portage/ucp/#{@slug}"
            require "webmock/rspec"

            WebMock.disable_net_connect!

            RSpec.configure do |config|
              config.expect_with(:rspec) { |c| c.syntax = :expect }
              config.disable_monkey_patching!
              config.order = :random
            end
          RUBY
        end

        def write_conformance_spec
          write "spec/portage/ucp/#{@slug}/conformance_spec.rb", <<~RUBY
            require "spec_helper"
            require "portage/ucp/rspec"

            RSpec.describe Portage::Ucp::#{@module_name}::Adapter do
              let(:adapter) { described_class.new }
              let(:existing_product_id) { "TODO-a-real-catalog-id" }

              # TODO: stub whatever HTTP calls the kit's examples below need —
              # see portage-ucp-etsy/spec/.../conformance_spec.rb for a worked
              # example of stubbing just enough for a catalog+checkout adapter.
              it_behaves_like "a portage adapter"
            end
          RUBY
        end
      end
    end
  end
end
