# frozen_string_literal: true

require "spec_helper"

# The env-proxy behaviour itself is covered in portage-ucp's
# proxy_support_spec; this only pins that the token exchange goes through
# Support::Connection on the :platform route.
RSpec.describe "env-proxy support via Support::Connection (portage-ucp-instagram)" do
  it "routes the token-exchange GET through Support::Connection on the :platform route" do
    fetcher = Portage::Ucp::Instagram::AccessTokenFetcher.new(client_id: "id", client_secret: "secret",
                                                              short_lived_token: "short")
    expect(Portage::Ucp::Support::Connection).to receive(:start)
      .with(anything, hash_including(route: :platform)).and_raise(IOError)

    expect { fetcher.fetch }.to raise_error(IOError)
  end
end
