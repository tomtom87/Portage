require "spec_helper"

module TestPlatform
  class Error < StandardError; end

  class ApiError < Error
    include Portage::Ucp::Support::ApiError

    private

    def detail(body) = body["message"] || body
  end

  class RelabeledApiError < ApiError
    private

    def api_label = "TestPlatform/Graph"
  end
end

RSpec.describe Portage::Ucp::Support::ApiError do
  it "exposes the HTTP status and parsed body" do
    error = TestPlatform::ApiError.new(422, { "message" => "nope" })
    expect([error.status, error.body]).to eq([422, { "message" => "nope" }])
  end

  it "builds a message from the platform label, status and the detail hook" do
    expect(TestPlatform::ApiError.new(404, { "message" => "not found" }).message)
      .to eq("TestPlatform API error (404): not found")
  end

  it "falls back to the whole body when the detail hook finds nothing" do
    expect(TestPlatform::ApiError.new(500, { "unexpected" => true }).message)
      .to include("TestPlatform API error (500):", "unexpected")
  end

  it "lets a gem override the label where the API's public name isn't the gem's" do
    expect(TestPlatform::RelabeledApiError.new(400, { "message" => "bad" }).message)
      .to eq("TestPlatform/Graph API error (400): bad")
  end

  it "leaves the including gem's own error hierarchy intact" do
    expect(TestPlatform::ApiError.new(404, {})).to be_a(TestPlatform::Error)
  end
end
