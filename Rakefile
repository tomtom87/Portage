# Root aggregate task only — each gem still owns its own tests/lint
# independently (own Gemfile.lock, own bundle, no shared state), matching
# README's "Development" section. This just saves typing out the same
# `cd gem && bundle exec rspec && bundle exec rubocop` ten times by hand.
GEMS = %w[
  portage-ucp
  portage-ucp-journal
  portage-ucp-client
  portage-cli
  portage-ucp-shopify
  portage-ucp-wix
  portage-ucp-woocommerce
  portage-ucp-bigcommerce
  portage-ucp-magento
  portage-ucp-etsy
  portage-ucp-instagram
].freeze

ADAPTER_GEMS = %w[
  portage-ucp-shopify
  portage-ucp-wix
  portage-ucp-woocommerce
  portage-ucp-bigcommerce
  portage-ucp-magento
  portage-ucp-etsy
  portage-ucp-instagram
].freeze

desc "Fail if any bundled adapter gem's spec suite doesn't run the shared " \
     "conformance kit (design-log §17) — catches an adapter drifting from " \
     "the Adapter contract without anyone having to notice a missing spec."
task :conformance do
  missing = ADAPTER_GEMS.reject do |gem_dir|
    Dir.glob(File.join(gem_dir, "spec", "**", "*_spec.rb")).any? do |spec_file|
      File.read(spec_file).include?('it_behaves_like "a portage adapter"')
    end
  end

  abort "Adapter gem(s) missing \"a portage adapter\" conformance coverage: #{missing.join(', ')}" unless missing.empty?

  puts "All #{ADAPTER_GEMS.size} adapter gems run the shared conformance kit."
end

desc "Run rspec + rubocop for every gem, in order, stopping at the first failure"
task :spec do
  GEMS.each do |gem_dir|
    puts "\n=== #{gem_dir} ==="
    Dir.chdir(gem_dir) do
      sh "bundle exec rspec" do |ok, _res|
        abort "#{gem_dir}: rspec failed" unless ok
      end
      sh "bundle exec rubocop" do |ok, _res|
        abort "#{gem_dir}: rubocop failed" unless ok
      end
    end
  end
end

# Builds a gem from its own directory and smoke-tests that the built package
# installs and requires cleanly (postmortem for the 0.7.0-line yank: `gem
# build` run from the workspace root resolved every gemspec's
# `Dir["lib/**/*.rb"]` against the wrong cwd, so all ten packages shipped
# with no `lib/` and nobody noticed before pushing). Yields the built gem's
# path (inside a tmpdir that's cleaned up on return) so callers can push it
# without re-building.
def build_and_verify_gem(gem_dir)
  require "tmpdir"
  require "fileutils"

  Dir.mktmpdir do |tmp|
    gem_file = Dir.chdir(gem_dir) do
      sh "gem build #{gem_dir}.gemspec"
      built = Dir.glob("#{gem_dir}-*.gem").max_by { |f| File.mtime(f) }
      abort "gem build produced no .gem file in #{gem_dir}/ — check the gemspec" unless built
      FileUtils.mv(built, tmp)
      built
    end

    install_dir = File.join(tmp, "install")
    sh "gem install --local --install-dir #{install_dir} #{File.join(tmp, gem_file)}"

    gem_lib = Dir.glob(File.join(install_dir, "gems", "#{gem_dir}-*", "lib")).first
    abort "installed gem has no lib/ — this is exactly the 0.7.0-line bug" unless gem_lib

    require_name = gem_dir.tr("-", "/")
    sh "ruby -I #{gem_lib} -e \"require '#{require_name}'\" && echo '#{gem_dir}: require OK'"

    yield File.join(tmp, gem_file)
  end
end

desc "Build a gem from its own directory and smoke-test that the built " \
     "package installs and requires cleanly"
task :release_check, [:gem_dir] do |_t, args|
  gem_dir = args[:gem_dir]
  abort "usage: rake release_check[portage-ucp]" unless gem_dir
  abort "no such gem dir: #{gem_dir}" unless GEMS.include?(gem_dir)

  build_and_verify_gem(gem_dir) { |_gem_path| }
end

desc "Build, smoke-test, and push every gem to rubygems.org in dependency " \
     "order, using the same build_and_verify_gem check as release_check. " \
     "rubygems MFA requires a fresh OTP per push, so this pauses for input " \
     "at each `gem push` — run it once and answer the OTP prompt as it comes."
task :publish_all do
  GEMS.each do |gem_dir|
    puts "\n=== #{gem_dir} ==="
    build_and_verify_gem(gem_dir) { |gem_path| sh "gem push #{gem_path}" }
  end
end

task default: :spec
