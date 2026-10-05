require "spec_helper"

RSpec.describe Portage::Cli::HomepageFetch do
  it "follows a redirect on the same route it was called with" do
    stub_request(:get, "https://shop.example/")
      .to_return(status: 301, headers: { "Location" => "https://www.shop.example/" })
    stub_request(:get, "https://www.shop.example/").to_return(status: 200, body: "<html>shop</html>")
    routes = []
    allow(Portage::Ucp::Support::Connection).to receive(:start).and_wrap_original do |original, uri, **kwargs, &block|
      routes << kwargs[:route]
      original.call(uri, **kwargs, &block)
    end

    body, = described_class.call(URI("https://shop.example/"), route: :payment)

    expect(body).to eq("<html>shop</html>")
    expect(routes).to eq(%i[payment payment])
  end
end
