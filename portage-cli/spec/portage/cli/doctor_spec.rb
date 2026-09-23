require "spec_helper"

RSpec.describe Portage::Cli::Doctor do
  # Portage::Ucp.configuration memoizes a single Configuration instance —
  # reset it around each example so one test's config.signing_keys= etc.
  # doesn't leak into the next.
  around do |example|
    Portage::Ucp.instance_variable_set(:@configuration, nil)
    example.run
    Portage::Ucp.instance_variable_set(:@configuration, nil)
  end

  it "flags every collaborator still at its unconfigured default" do
    with_env("JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => nil) do
      findings = described_class.new.call

      expect(findings.map(&:check)).to contain_exactly("authenticator", "rate_limiter", "signing_keys",
                                                       "payment_handlers", "jev_api_key")
    end
  end

  it "clears a finding once its collaborator is configured" do
    Portage::Ucp.configure do |config|
      config.authenticator = ->(_ctx) { "auth-context" }
      config.rate_limiter = Class.new { def check!(*); end }.new
      config.signing_keys = [{ kid: "k1" }]
      config.payment_handlers = [{ name: "stripe" }]
    end

    with_env("JEV_API_KEY" => "test-key") do
      expect(described_class.new.call).to be_empty
    end
  end

  it "flags a missing JEV_API_KEY with a link to get one" do
    with_env("JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => nil) do
      finding = described_class.new.call.find { |f| f.check == "jev_api_key" }

      expect(finding.message).to include("console.typesafe.ai")
    end
  end

  it "accepts TYPESAFE_API_KEY in place of JEV_API_KEY, since ModelBackends::Jev falls back to it" do
    with_env("JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => "test-key") do
      expect(described_class.new.call.map(&:check)).not_to include("jev_api_key")
    end
  end

  it "flags a capability implemented on some but not all of its actions" do
    adapter_class = Class.new(Portage::Ucp::Adapter) do
      def search_catalog(**) = []
    end

    findings = described_class.new(adapter_class: adapter_class).call

    catalog_finding = findings.find { |f| f.check == "capability:dev.ucp.shopping.catalog" }
    expect(catalog_finding.message).to include("1/3")
  end

  it "doesn't flag a capability with none or all of its actions implemented" do
    untouched_adapter = Class.new(Portage::Ucp::Adapter)

    findings = described_class.new(adapter_class: untouched_adapter).call

    expect(findings.map(&:check)).to all(satisfy { |c| !c.start_with?("capability:") })
  end
end
