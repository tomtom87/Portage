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

task default: :spec
