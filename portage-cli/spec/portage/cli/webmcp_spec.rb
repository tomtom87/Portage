require "spec_helper"

RSpec.describe Portage::Cli::Webmcp do
  # portage-ucp-webmcp is in the dev bundle (see Gemfile), so the real
  # require succeeds here — this just proves the memoized lazy-require
  # pattern doesn't blow up, the same way Decisions.available? is covered.
  it "is available when portage-ucp-webmcp is installed" do
    expect(described_class.available?).to be true
  end

  it "treats a portage-ucp-webmcp older than 0.2.0 as unsupported" do
    expect(described_class.supported?("0.1.1")).to be false
    expect(described_class.supported?("0.2.0")).to be true
  end
end
