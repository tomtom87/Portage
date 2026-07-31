# Root aggregate task only — each gem still owns its own tests/lint
# independently (own Gemfile.lock, own bundle, no shared state), matching
# README's "Development" section. This just saves typing out the same
# `cd gem && bundle exec rspec && bundle exec rubocop` five times by hand.
GEMS = %w[
  portage-ucp
  portage-ucp-shopify
  portage-ucp-wix
  portage-ucp-woocommerce
  portage-ucp-bigcommerce
  portage-ucp-magento
].freeze

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
