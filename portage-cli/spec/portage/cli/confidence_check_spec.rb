require "spec_helper"

RSpec.describe Portage::Cli::ConfidenceCheck do
  around { |example| with_env("PORTAGE_DECISION_BACKEND" => nil, "PORTAGE_MIN_CONFIDENCE" => nil) { example.run } }

  def backend_answering(noul)
    backend = Object.new
    backend.define_singleton_method(:ask) do |state:, questions:|
      @state = state
      questions.transform_values do
        Portage::Ucp::Decision::ModelBackends::Answer.new(type: "noul", confidence: nil, value: noul)
      end
    end
    backend.define_singleton_method(:state) { @state }
    backend
  end

  it "is disabled, and answers nil, when no backend is named" do
    check = described_class.new

    expect(check.enabled?).to be false
    expect(check.call(query: "cold")).to be_nil
  end

  it "reads the backend and threshold from PORTAGE_DECISION_BACKEND / PORTAGE_MIN_CONFIDENCE" do
    backend = backend_answering(0.6)
    resolver = ->(name) { name == "jev" ? backend : raise("unexpected #{name}") }
    verdict = with_env("PORTAGE_DECISION_BACKEND" => "jev", "PORTAGE_MIN_CONFIDENCE" => "0.5") do
      described_class.new(resolver: resolver).call(query: "cold")
    end

    expect(verdict).to eq(proceed: true, reason: nil, confidence: 0.6, threshold: 0.5, backend: "jev", error: nil)
  end

  it "lets explicit arguments win over the env vars" do
    backend = backend_answering(0.6)
    verdict = with_env("PORTAGE_DECISION_BACKEND" => "laya", "PORTAGE_MIN_CONFIDENCE" => "0.5") do
      described_class.new(backend: "jev", threshold: 0.9, resolver: ->(_name) { backend }).call(query: "cold")
    end

    expect(verdict).to include(proceed: false, reason: "below_threshold", threshold: 0.9, backend: "jev", error: nil)
  end

  it "defaults the threshold to DEFAULT_THRESHOLD" do
    verdict = described_class.new(backend: "jev", resolver: ->(_name) { backend_answering(0.79) }).call({})

    expect(verdict).to include(proceed: false, threshold: described_class::DEFAULT_THRESHOLD)
  end

  it "sends the state to the backend as JSON" do
    backend = backend_answering(0.9)
    described_class.new(backend: "jev", resolver: ->(_name) { backend }).call(query: "cold", quantity: 2)

    expect(JSON.parse(backend.state)).to eq("query" => "cold", "quantity" => 2)
  end

  it "fails closed on an unknown backend name" do
    verdict = described_class.new(backend: "nope").call({})

    expect(verdict).to include(proceed: false, reason: "backend_error", backend: "nope")
    expect(verdict[:error]).to include("unknown decision model backend")
  end

  it "fails closed when the backend isn't configured" do
    verdict = with_env("JEV_API_KEY" => nil, "TYPESAFE_API_KEY" => nil) do
      described_class.new(backend: "jev").call({})
    end

    expect(verdict).to include(proceed: false, reason: "backend_error", confidence: nil)
    expect(verdict[:error]).to include("JEV_API_KEY is not set")
  end

  it "fails closed, naming the gem, when a backend is named but portage-ucp-decision isn't installed" do
    allow(Portage::Cli::Decisions).to receive(:available?).and_return(false)
    verdict = described_class.new(backend: "jev", resolver: ->(_name) { raise "must not resolve" }).call({})

    expect(verdict).to include(proceed: false, reason: "not_installed", backend: "jev")
    expect(verdict[:error]).to include("gem install portage-ucp-decision")
  end

  it "rejects a threshold outside 0.0..1.0" do
    expect { described_class.new(backend: "jev", threshold: 1.5) }.to raise_error(ArgumentError, /between 0.0 and 1.0/)
  end

  it "rejects a non-numeric PORTAGE_MIN_CONFIDENCE" do
    with_env("PORTAGE_MIN_CONFIDENCE" => "high") do
      expect { described_class.new }.to raise_error(ArgumentError, /"high"/)
    end
  end
end
