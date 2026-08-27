require "spec_helper"

RSpec.describe Portage::Ucp::Support::Retry do
  let(:retryable_error_class) do
    Class.new(StandardError) do
      attr_reader :status, :retry_after

      def initialize(status:, retry_after: nil)
        @status = status
        @retry_after = retry_after
        super("boom")
      end
    end
  end

  let(:caller_class) do
    Class.new do
      include Portage::Ucp::Support::Retry

      def call(&block)
        with_retry(base_delay: 0, max_delay: 0, &block)
      end
    end
  end

  it "is private — with_retry is adapter/client-internal, not part of the Adapter contract" do
    expect(caller_class.new).not_to respond_to(:with_retry)
  end

  it "returns the block's value on first success" do
    expect(caller_class.new.call { "ok" }).to eq("ok")
  end

  it "retries a 429 and returns the eventual success" do
    instance = caller_class.new
    allow(instance).to receive(:sleep)
    attempts = 0

    result = instance.call do
      attempts += 1
      raise retryable_error_class.new(status: 429) if attempts < 3

      "ok"
    end

    expect(result).to eq("ok")
    expect(attempts).to eq(3)
  end

  it "retries a 5xx" do
    instance = caller_class.new
    allow(instance).to receive(:sleep)
    attempts = 0

    instance.call do
      attempts += 1
      raise retryable_error_class.new(status: 503) if attempts < 2

      "ok"
    end

    expect(attempts).to eq(2)
  end

  it "raises once attempts are exhausted" do
    instance = caller_class.new
    allow(instance).to receive(:sleep)
    attempts = 0

    expect do
      instance.call do
        attempts += 1
        raise retryable_error_class.new(status: 429)
      end
    end.to raise_error(retryable_error_class)

    expect(attempts).to eq(Portage::Ucp::Support::Retry::DEFAULT_MAX_ATTEMPTS)
  end

  it "does not retry a non-retryable error" do
    instance = caller_class.new
    allow(instance).to receive(:sleep)
    attempts = 0

    expect do
      instance.call do
        attempts += 1
        raise retryable_error_class.new(status: 404)
      end
    end.to raise_error(retryable_error_class)

    expect(attempts).to eq(1)
  end

  it "does not retry an error with no status at all" do
    instance = caller_class.new
    allow(instance).to receive(:sleep)
    attempts = 0

    expect do
      instance.call do
        attempts += 1
        raise Portage::Ucp::ConflictError, "stale read"
      end
    end.to raise_error(Portage::Ucp::ConflictError)

    expect(attempts).to eq(1)
  end

  it "honors Retry-After over exponential backoff" do
    instance = caller_class.new
    expect(instance).to receive(:sleep).with(5.0)
    attempts = 0

    instance.call do
      attempts += 1
      raise retryable_error_class.new(status: 429, retry_after: 5.0) if attempts < 2

      "ok"
    end
  end
end
