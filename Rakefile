require "English"

# Root aggregate task only — each gem still owns its own tests/lint
# independently (own Gemfile.lock, own bundle, no shared state), matching
# README's "Development" section. This just saves typing out the same
# `cd gem && bundle exec rspec && bundle exec rubocop` ten times by hand.
GEMS = %w[
  portage-ucp
  portage-ucp-journal
  portage-ucp-client
  portage-ucp-webmcp
  portage-ucp-decision
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
#
# `gem_cache:` is a directory of downloaded `.gem` files shared across
# calls: it seeds this install's cache, which `gem install` checks before
# downloading, so `publish_all` fetches each dependency once rather than
# once per adapter. The install dir itself stays per gem on purpose: any
# gem in GEM_HOME is requirable, so a shared one would let a dependency a
# gemspec forgot to declare pass the require check below.
def build_and_verify_gem(gem_dir, gem_cache: nil)
  require "tmpdir"
  require "fileutils"

  Dir.mktmpdir do |tmp|
    # --output writes the package straight into the tmpdir. Building into the
    # gem's own directory and moving it afterwards left a window where a
    # killed process stranded a `.gem` in the source tree — invisible to `git
    # status`, since `.gitignore` ignores `*.gem`.
    gem_file = File.join(tmp, "#{gem_dir}.gem")
    Dir.chdir(gem_dir) { sh "gem build #{gem_dir}.gemspec --output #{gem_file}" }
    abort "gem build produced no .gem file for #{gem_dir} — check the gemspec" unless File.exist?(gem_file)

    install_dir = File.join(tmp, "install")
    cache_dir = File.join(install_dir, "cache")
    if gem_cache
      FileUtils.mkdir_p(cache_dir)
      FileUtils.cp(Dir[File.join(gem_cache, "*.gem")], cache_dir)
    end
    sh "gem install --no-document --install-dir #{install_dir} #{gem_file}"
    FileUtils.cp(Dir[File.join(cache_dir, "*.gem")], gem_cache) if gem_cache

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

OPENCLAW_DIR = "openclaw-plugin".freeze
BUY_PLUGIN_JSON = "plugins/buy/.claude-plugin/plugin.json".freeze

# The OpenClaw plugin ships the buy plugin's skills, so its version follows
# the buy plugin's (the same rule portage-cli's packaging spec holds each
# skill's `version` to). Compared as strings, exactly, like that spec.
def openclaw_version_mismatch
  require "json"

  buy = JSON.parse(File.read(BUY_PLUGIN_JSON)).fetch("version")
  openclaw = JSON.parse(File.read(File.join(OPENCLAW_DIR, "package.json"))).fetch("version")
  openclaw == buy ? nil : "#{OPENCLAW_DIR}/package.json is #{openclaw} but #{BUY_PLUGIN_JSON} is #{buy}"
end

# Paths `npm pack` must include, as seen in `npm pack --dry-run --json`'s file
# list: compiled output, the manifest, and all three skills (the first two are
# copied in by the build, so a package from a tree that never built lacks them).
OPENCLAW_PACK_REQUIRED = {
  "dist/" => %r{\Adist/.+},
  "openclaw.plugin.json" => /\Aopenclaw\.plugin\.json\z/,
  "skills/buy/SKILL.md" => %r{\Askills/buy/SKILL\.md\z},
  "skills/shop-research/SKILL.md" => %r{\Askills/shop-research/SKILL\.md\z},
  "skills/portage-openclaw/SKILL.md" => %r{\Askills/portage-openclaw/SKILL\.md\z}
}.freeze

def openclaw_pack_missing(paths)
  OPENCLAW_PACK_REQUIRED.reject { |_name, pattern| paths.any? { |path| path.match?(pattern) } }.keys
end

namespace :openclaw do
  desc "Fail if openclaw-plugin/package.json's version isn't the buy plugin's"
  task :version_check do
    mismatch = openclaw_version_mismatch
    abort "OpenClaw plugin version drift: #{mismatch}" if mismatch

    puts "openclaw-plugin version matches the buy plugin."
  end

  desc "Build openclaw-plugin, then fail unless `npm pack --dry-run` would ship dist/, the manifest and all " \
       "three skills. Offline: a dry run packs nothing and publishes nothing."
  task :pack_check do
    require "json"
    require "open3"

    Dir.chdir(OPENCLAW_DIR) do
      sh "npm run build" do |ok, _res|
        abort "openclaw-plugin: npm run build failed" unless ok
      end

      output, error, status = Open3.capture3("npm", "pack", "--dry-run", "--json")
      abort "openclaw-plugin: npm pack --dry-run failed:\n#{error}" unless status.success?

      paths = JSON.parse(output).flat_map { |pack| pack.fetch("files") }.map { |file| file.fetch("path") }
      missing = openclaw_pack_missing(paths)
      abort "openclaw-plugin: npm pack would not ship: #{missing.join(', ')}" unless missing.empty?

      puts "openclaw-plugin pack lists #{paths.size} files, including dist/, openclaw.plugin.json and all three skills."
    end
  end

  desc "Version and pack checks for the OpenClaw plugin"
  task release_check: %i[version_check pack_check]
end

desc "Build a gem from its own directory and smoke-test that the built " \
     "package installs and requires cleanly"
task :release_check, [:gem_dir] do |_t, args|
  gem_dir = args[:gem_dir]
  abort "usage: rake release_check[portage-ucp]" unless gem_dir
  abort "no such gem dir: #{gem_dir}" unless GEMS.include?(gem_dir)

  build_and_verify_gem(gem_dir) { |_gem_path| }
  Rake::Task["openclaw:release_check"].invoke
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
  require "tmpdir"

  # Before any push: a drifted or incomplete OpenClaw package shouldn't be
  # found out after the gems are already on rubygems.org.
  Rake::Task["openclaw:release_check"].invoke

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

  Dir.mktmpdir do |gem_cache|
    to_publish.each do |gem_dir|
      puts "\n=== #{gem_dir} #{gemspec_version(gem_dir)} ==="
      build_and_verify_gem(gem_dir, gem_cache: gem_cache) { |gem_path| sh "gem push #{gem_path}" }
    end
  end

  if ENV["SKIP_HOMEBREW"]
    puts "\nSKIP_HOMEBREW set — run `rake homebrew:update` once you're ready to update the tap."
  else
    puts "\nEvery gem is pushed. Updating the Homebrew tap (a failure here leaves " \
         "the gems published; fix it and re-run `rake homebrew:update`)."
    Rake::Task["homebrew:update"].invoke
  end
end

HOMEBREW_TAP = "tomtom87/portage".freeze
HOMEBREW_FORMULA = "#{HOMEBREW_TAP}/portage".freeze

namespace :homebrew do
  desc "Regenerate the tap's Formula/portage.rb from this checkout's versions, " \
       "install and test it locally, then commit and push the tap. The tap has " \
       "no CI, so this is its only test run. NO_PUSH=1 stops after the local " \
       "commit."
  task :update do
    tap_dir = `brew --repository #{HOMEBREW_TAP}`.strip
    abort "Homebrew tap not found at #{tap_dir} — run `brew tap #{HOMEBREW_TAP}` first" \
      unless File.directory?(File.join(tap_dir, ".git"))

    git = ->(args) { sh "git -C #{tap_dir} #{args}" }
    tap_status = `git -C #{tap_dir} status --porcelain`
    abort "Tap checkout #{tap_dir} has uncommitted changes:\n#{tap_status}" unless tap_status.empty?
    git.call("pull --ff-only --quiet")

    formula_path = File.join(tap_dir, "Formula", "portage.rb")
    write_homebrew_formula(formula_path)

    if `git -C #{tap_dir} status --porcelain`.empty?
      puts "Formula/portage.rb is already up to date — nothing to commit."
      next
    end

    # Test the working-tree formula itself, not a copy from Homebrew's API.
    brew_env = { "HOMEBREW_NO_AUTO_UPDATE" => "1", "HOMEBREW_NO_INSTALL_FROM_API" => "1" }
    installed = system(brew_env, "brew list --formula #{HOMEBREW_FORMULA} >/dev/null 2>&1")
    begin
      sh brew_env, "brew #{installed ? 'reinstall' : 'install'} --build-from-source #{HOMEBREW_FORMULA}"
      sh brew_env, "brew test #{HOMEBREW_FORMULA}"
      sh brew_env, "brew style #{HOMEBREW_FORMULA}"
      sh brew_env, "brew audit --strict --online #{HOMEBREW_FORMULA}"
    rescue RuntimeError
      abort "The new formula failed locally; it's left uncommitted in #{formula_path} for inspection."
    end

    git.call("add Formula/portage.rb")
    git.call("commit --quiet -m 'portage #{gemspec_version('portage-cli')}'")
    if ENV["NO_PUSH"]
      puts "NO_PUSH set — committed in #{tap_dir} but not pushed."
    else
      git.call("push --quiet")
      puts "Pushed portage #{gemspec_version('portage-cli')} to #{HOMEBREW_TAP}."
    end
  end
end

# Runs script/homebrew-formula into `path`, retrying while rubygems.org still
# answers that a just-pushed gem "isn't published". Its CDN keeps serving the
# pre-push version list for a while even with `Cache-Control: no-cache`, so
# straight after `publish_all` the first attempts routinely fail.
def write_homebrew_formula(path, attempts: 20, delay: 15)
  require "open3"

  attempts.times do |attempt|
    output, status = Open3.capture2e(RbConfig.ruby, "script/homebrew-formula", "--out", path)
    if status.success?
      puts output
      return
    end
    abort "script/homebrew-formula failed:\n#{output}" unless output.include?("isn't published on rubygems.org yet")

    puts "rubygems.org doesn't list every new version yet (attempt #{attempt + 1}/#{attempts}); retrying in #{delay}s…"
    sleep delay
  end
  abort "Gave up waiting for rubygems.org to list the new versions. Re-run `rake homebrew:update` later."
end

# Every file this repo publishes over jsdelivr's `@main` channel, by short
# name — agent-profile.json (docs/agent-profile.md) plus, as of Phase 2c
# (docs/plans/buy-skill-and-local-browser.md), the known-stores list
# `portage index build --export` writes a PR into. One purge task covers
# all of them (`rake jsdelivr:purge`) rather than growing a bespoke task
# per published file.
JSDELIVR_PATHS = {
  "agent_profile" => "gh/tomtom87/Portage@main/portage-cli/agent-profile/agent-profile.json",
  "known_stores" => "gh/tomtom87/Portage@main/portage-cli/known-stores/stores.json",
  "known_products" => "gh/tomtom87/Portage@main/portage-cli/known-stores/products.json"
}.freeze

def purge_jsdelivr_path(path)
  require "net/http"

  uri = URI("https://purge.jsdelivr.net/#{path}")
  response = Net::HTTP.get_response(uri)
  abort "jsdelivr purge failed for #{path}: #{response.code} #{response.body}" unless response.is_a?(Net::HTTPSuccess)

  puts "Purged https://cdn.jsdelivr.net/#{path}"
end

namespace :jsdelivr do
  desc "Purge jsdelivr's CDN cache for one (rake jsdelivr:purge[known_stores]) or, with no argument, every " \
       "file this repo publishes (see JSDELIVR_PATHS) — required after any change to one of them. @main is " \
       "cached for up to a week; skipping this reproduces the §42 `Tool not found` registry miss against " \
       "otherwise-correct, already-pushed code."
  task :purge, [:name] do |_t, args|
    names = args[:name] ? [args[:name]] : JSDELIVR_PATHS.keys
    unknown = names - JSDELIVR_PATHS.keys
    unless unknown.empty?
      abort "Unknown jsdelivr path name(s): #{unknown.join(', ')} (known: #{JSDELIVR_PATHS.keys.join(', ')})"
    end

    names.each { |name| purge_jsdelivr_path(JSDELIVR_PATHS.fetch(name)) }
  end
end

namespace :agent_profile do
  desc "Alias for `rake jsdelivr:purge[agent_profile]`, kept working so an existing habit/script " \
       "(docs/agent-profile.md) doesn't break."
  task :purge do
    Rake::Task["jsdelivr:purge"].invoke("agent_profile")
  end
end

task default: :spec
