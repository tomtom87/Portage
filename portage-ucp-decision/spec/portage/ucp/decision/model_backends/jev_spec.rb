require "spec_helper"

RSpec.describe Portage::Ucp::Decision::ModelBackends::Jev do
  let(:question) do
    Portage::Ucp::Decision::ModelBackends::Question.new(type: "noul", instructions: "Does this express urgency?")
  end

  it "raises BackendNotConfiguredError without an api key" do
    backend = described_class.new(api_key: nil)

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendNotConfiguredError, /JEV_API_KEY/)
  end

  it "reads the api key from JEV_API_KEY by default and uses it as the Bearer token" do
    original = ENV.fetch("JEV_API_KEY", nil)
    ENV["JEV_API_KEY"] = "from-env"
    stub_request(:post, described_class::BASE_URL)
      .with(headers: { "Authorization" => "Bearer from-env" })
      .to_return(status: 200, body: { answers: { "urgency" => { type: "noul", confidence: 0.5 } } }.to_json)

    expect(described_class.new.ask(state: "help!", questions: { "urgency" => question })["urgency"].confidence)
      .to eq(0.5)
  ensure
    ENV["JEV_API_KEY"] = original
  end

  it "posts the state and questions, and returns typed answers with confidence" do
    stub_request(:post, described_class::BASE_URL)
      .with(headers: { "Authorization" => "Bearer test-key" },
            body: { state: "help!", model: "jev-latest",
                    questions: { "urgency" => { "type" => "noul", "instructions" => "Does this express urgency?" } } })
      .to_return(status: 200, body: { model: "jev-1.13.0",
                                      answers: { "urgency" => { type: "noul", confidence: 0.91, noul: 1.0 } } }.to_json)

    backend = described_class.new(api_key: "test-key")
    answers = backend.ask(state: "help!", questions: { "urgency" => question })

    expect(answers["urgency"].confidence).to eq(0.91)
    expect(answers["urgency"].value).to eq(1.0)
  end

  it "raises BackendError on a non-2xx response" do
    stub_request(:post, described_class::BASE_URL).to_return(status: 500, body: "boom")

    backend = described_class.new(api_key: "test-key")

    expect { backend.ask(state: "help!", questions: { "urgency" => question }) }
      .to raise_error(Portage::Ucp::Decision::BackendError, /500/)
  end
end
