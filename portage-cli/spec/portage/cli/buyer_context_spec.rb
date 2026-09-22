require "spec_helper"

RSpec.describe Portage::Cli::BuyerContext do
  around do |example|
    saved = described_class::ENV_VARS.values.to_h { |var| [var, ENV.fetch(var, nil)] }
    described_class::ENV_VARS.each_value { |var| ENV.delete(var) }
    example.run
    saved.each { |var, value| value.nil? ? ENV.delete(var) : ENV[var] = value }
  end

  it "reads the shipping country/region/postal code and currency/language" do
    ENV["PORTAGE_SHIP_COUNTRY"] = "US"
    ENV["PORTAGE_SHIP_REGION"] = "CA"
    ENV["PORTAGE_SHIP_POSTAL_CODE"] = "94103"
    ENV["PORTAGE_CURRENCY"] = "USD"
    ENV["PORTAGE_LANGUAGE"] = "en"

    expect(described_class.from_env).to eq(
      address_country: "US", address_region: "CA", postal_code: "94103", currency: "USD", language: "en"
    )
  end

  # Deliberately unlike Portage::Cli::ShippingProfile, which is all-or-nothing
  # because a partial address can't be submitted. A context is specified as
  # provisional hints, and a country alone resolves a market, so a partial one
  # is worth sending.
  it "returns whatever subset is configured rather than requiring the full set" do
    ENV["PORTAGE_SHIP_COUNTRY"] = "GB"

    expect(described_class.from_env).to eq(address_country: "GB")
  end

  it "ignores empty values" do
    ENV["PORTAGE_SHIP_COUNTRY"] = "US"
    ENV["PORTAGE_CURRENCY"] = ""

    expect(described_class.from_env).to eq(address_country: "US")
  end

  # Returns {} rather than nil so callers pass it through unconditionally —
  # Transports::Http drops an empty context off the wire itself.
  it "returns an empty hash when nothing is configured" do
    expect(described_class.from_env).to eq({})
  end
end
