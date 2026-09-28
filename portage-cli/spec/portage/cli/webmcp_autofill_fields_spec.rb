require "spec_helper"

RSpec.describe Portage::Cli::WebmcpAutofillFields do
  def with_ship_env(vars, &)
    blank = Portage::Cli::ShippingProfile::ENV_VARS.values.to_h { |var| [var, nil] }
    with_env(blank.merge("PORTAGE_SHIP_EMAIL" => nil).merge(vars), &)
  end

  let(:required) do
    { "PORTAGE_SHIP_STREET" => "1 Main St", "PORTAGE_SHIP_CITY" => "Erie", "PORTAGE_SHIP_COUNTRY" => "US",
      "PORTAGE_SHIP_POSTAL_CODE" => "16501" }
  end

  it "maps a full shipping profile plus email onto autocomplete tokens" do
    fields = with_ship_env(required.merge("PORTAGE_SHIP_EMAIL" => "buyer@example.com",
                                          "PORTAGE_SHIP_FIRST_NAME" => "Jane")) { described_class.build }

    expect(fields).to include("email" => "buyer@example.com", "shipping given-name" => "Jane",
                              "shipping address-line1" => "1 Main St", "shipping address-level2" => "Erie",
                              "shipping country" => "US", "shipping postal-code" => "16501")
  end

  it "returns just the email when no shipping profile is configured" do
    fields = with_ship_env({ "PORTAGE_SHIP_EMAIL" => "buyer@example.com" }) { described_class.build }

    expect(fields).to eq("email" => "buyer@example.com")
  end

  it "returns just the address when no email is configured" do
    fields = with_ship_env(required) { described_class.build }

    expect(fields).not_to have_key("email")
    expect(fields["shipping address-line1"]).to eq("1 Main St")
  end

  it "returns an empty Hash when neither is configured — nothing to autofill" do
    expect(with_ship_env({}) { described_class.build }).to eq({})
  end

  it "leaves an unset optional field (e.g. no PORTAGE_SHIP_PHONE) out entirely" do
    fields = with_ship_env(required.merge("PORTAGE_SHIP_PHONE" => "")) { described_class.build }

    expect(fields).not_to have_key("shipping tel")
  end

  it "accepts an injected address, e.g. for a spec that doesn't want real env vars" do
    address = Portage::Ucp::PostalAddress.new(street_address: "42 Elm St", address_country: "CA")

    fields = with_ship_env({}) { described_class.build(address: address) }

    expect(fields).to eq("shipping address-line1" => "42 Elm St", "shipping country" => "CA")
  end
end
