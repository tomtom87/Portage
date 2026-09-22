require "English"

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

  Dir.mktmpdir do |tmp|
    # --output writes the package straight into the tmpdir. Building into the
    # gem's own directory and moving it afterwards left a window where a
    # killed process stranded a `.gem` in the source tree — invisible to `git
    # status`, since `.gitignore` ignores `*.gem`.
    gem_file = File.join(tmp, "#{gem_dir}.gem")
    Dir.chdir(gem_dir) { sh "gem build #{gem_dir}.gemspec --output #{gem_file}" }
    abort "gem build produced no .gem file for #{gem_dir} — check the gemspec" unless File.exist?(gem_file)

    install_dir = File.join(tmp, "install")
    sh "gem install --install-dir #{install_dir} #{gem_file}"

    # Pinned to the exact version rather than globbing `#{gem_dir}-*`: for
    # `portage-ucp` that wildcard also matches a `portage-ucp-client` or
    # `portage-ucp-journal` installed alongside it as a dependency, and
    # `.first` could hand the lib/ check a sibling gem — quietly satisfying
    # the very guard that exists to catch the 0.7.0-line empty-package bug.
    gem_lib = File.join(install_dir, "gems", "#{gem_dir}-#{gemspec_version(gem_dir)}", "lib")
    abort "installed gem has no lib/ — this is exactly the 0.7.0-line bug" unless Dir.exist?(gem_lib)

    # GEM_HOME/GEM_PATH point at the throwaway install dir so the require
    # resolves the gem's *dependencies* out of it too — `-I <gem>/lib` alone
    # only puts this one gem on the load path, so every gem with a portage
    # dependency failed here with "cannot load such file -- portage/ucp"
    # even though the package was fine. `-I` stays as the belt to the
    # gem_lib check's braces.
    require_name = gem_dir.tr("-", "/")
    sh "GEM_HOME=#{install_dir} GEM_PATH=#{install_dir} ruby -I #{gem_lib} -e " \
       "\"require '#{require_name}'\" && echo '#{gem_dir}: require OK'"

    yield gem_file
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

# Uncommitted or untracked changes under a gem's own directory. `gem build`
# packages the live working tree rather than a git export, so a stray
# `lib/portage/scratch.rb` ships silently — the gemspec's `Dir["lib/**/*.rb"]`
# can't tell it from a committed file. Scoped to the gem directory on purpose:
# untracked scratch under `docs/` or `tmp/` can't reach a package, so it
# shouldn't block a release.
def working_tree_changes(gem_dir)
  output = `git status --porcelain -- #{gem_dir}`
  abort "git status failed for #{gem_dir}" unless $CHILD_STATUS.success?

  output.lines.map(&:chomp)
end

# Version in the gem's own gemspec. Loaded from inside the gem directory so
# the gemspec's relative `Dir["lib/**/*.rb"]` resolves the way `gem build`
# will resolve it.
def gemspec_version(gem_dir)
  Dir.chdir(gem_dir) { Gem::Specification.load("#{gem_dir}.gemspec").version.to_s }
end

# Versions already on rubygems.org. A gem nobody has published yet 404s,
# which is a legitimate "nothing published" answer rather than an error.
def published_versions(gem_name)
  require "net/http"
  require "json"

  # `Cache-Control: no-cache` because the plain request is served by a CDN that
  # will happily hand back a body missing the newest versions — observed
  # returning a stale 6-version list for portage-ucp-client while 0.6.1 was
  # already live, five calls running, before clearing. A stale read makes a
  # published gem look unpublished, so `publish_all` burns an MFA prompt and
  # then dies on rubygems rejecting the duplicate push mid-run.
  uri = URI("https://rubygems.org/api/v1/versions/#{gem_name}.json")
  response = Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    http.request(Net::HTTP::Get.new(uri, "Cache-Control" => "no-cache", "Accept" => "application/json"))
  end
  return [] if response.is_a?(Net::HTTPNotFound)
  abort "rubygems.org version lookup for #{gem_name} failed: #{response.code}" unless response.is_a?(Net::HTTPSuccess)

  JSON.parse(response.body).map { |version| version["number"] }
end

desc "Build, smoke-test, and push every gem whose gemspec version isn't on " \
     "rubygems.org yet, in dependency order, using the same " \
     "build_and_verify_gem check as release_check. rubygems MFA requires a " \
     "fresh OTP per push, so this pauses for input at each `gem push`."
task :publish_all do
  to_publish = GEMS.reject do |gem_dir|
    version = gemspec_version(gem_dir)
    already_published = published_versions(gem_dir).include?(version)
    puts "#{gem_dir} #{version}: #{already_published ? 'already published, skipping' : 'to publish'}"
    already_published
  end

  if to_publish.empty?
    puts "\nEvery gem's current version is already on rubygems.org — nothing to push."
    next
  end

  dirty = to_publish.to_h { |gem_dir| [gem_dir, working_tree_changes(gem_dir)] }.reject { |_, changes| changes.empty? }

  unless dirty.empty?
    report = dirty.map { |gem_dir, changes| "#{gem_dir}:\n#{changes.map { |line| "  #{line}" }.join("\n")}" }
    abort "Refusing to publish from a dirty working tree — `gem build` packages " \
          "what's on disk, so these would ship as-is:\n#{report.join("\n")}"
  end

  puts "\n#{to_publish.size} gem(s) to push, so expect #{to_publish.size} MFA prompt(s)."

  to_publish.each do |gem_dir|
    puts "\n=== #{gem_dir} #{gemspec_version(gem_dir)} ==="
    build_and_verify_gem(gem_dir) { |gem_path| sh "gem push #{gem_path}" }
  end
end

task default: :spec
