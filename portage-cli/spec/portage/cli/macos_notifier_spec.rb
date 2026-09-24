require "spec_helper"

RSpec.describe Portage::Cli::MacosNotifier do
  describe "#call" do
    it "does nothing off Darwin" do
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("linux-gnu")
      notifier = described_class.new
      allow(notifier).to receive(:system)

      expect(notifier.call(title: "t", message: "m")).to be false
      expect(notifier).not_to have_received(:system)
    end

    it "shells out to osascript in array form on Darwin" do
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("darwin23")
      notifier = described_class.new
      allow(notifier).to receive(:system).and_return(true)

      result = notifier.call(title: "Portage checkout complete", message: "shop.example — 42.00 USD")

      expect(notifier).to have_received(:system).with("osascript", "-e", a_string_matching(/display notification/))
      expect(result).to be true
    end

    # A merchant/amount is untrusted text — this proves it can't break out
    # of its quoted AppleScript string to run something else.
    it "escapes a message that tries to break out of the quoted AppleScript string" do
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("darwin23")
      notifier = described_class.new
      captured = nil
      allow(notifier).to receive(:system) { |*args|
        captured = args.last
        true
      }

      notifier.call(title: "t", message: 'foo" & do shell script "rm -rf ~" & "')

      expect(captured).to include('foo\" & do shell script \"rm -rf ~\" & \"')
    end

    it "returns false instead of raising when system itself blows up" do
      allow(RbConfig::CONFIG).to receive(:[]).with("host_os").and_return("darwin23")
      notifier = described_class.new
      allow(notifier).to receive(:system).and_raise(Errno::ENOENT)

      expect(notifier.call(title: "t", message: "m")).to be false
    end
  end
end
