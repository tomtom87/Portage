require "spec_helper"

RSpec.describe Portage::Cli::ShippingProfile do
  def with_ship_env(vars, &)
    blank = described_class::ENV_VARS.values.to_h { |var| [var, nil] }
    with_env(blank.merge(vars), &)
  end

  let(:required) do
    { "PORTAGE_SHIP_STREET" => "1 Main St", "PORTAGE_SHIP_CITY" => "Erie", "PORTAGE_SHIP_COUNTRY" => "US",
      "PORTAGE_SHIP_POSTAL_CODE" => "16501" }
  end

  it "builds an address once every required field is set" do
    address = with_ship_env(required) { described_class.from_env }

    expect(address.to_h).to include(street_address: "1 Main St", address_country: "US")
  end

  it "treats an empty value as unset, so a .env copied with blanks left in submits nothing" do
    expect(with_ship_env(required.merge("PORTAGE_SHIP_CITY" => "")) { described_class.from_env }).to be_nil
  end

  it "leaves an empty optional field out of the address" do
    address = with_ship_env(required.merge("PORTAGE_SHIP_PHONE" => "")) { described_class.from_env }

    expect(address.phone_number).to be_nil
  end
end
