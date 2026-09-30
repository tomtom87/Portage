require "spec_helper"

RSpec.describe Portage::Cli::Index::Sources::StorefrontProducts::Robots do
  def allowed?(body, path = "/products.json?limit=250&page=1", agent: "portage-cli/0.10.0")
    described_class.new(body).allowed?(path, agent: agent)
  end

  it "allows everything for an empty or missing robots.txt" do
    expect(allowed?(nil)).to be(true)
    expect(allowed?("")).to be(true)
  end

  it "allows a Shopify default robots.txt, which never names /products.json" do
    body = <<~ROBOTS
      User-agent: *
      Allow: /
      Disallow: /admin
      Disallow: /cart.js
      Disallow: /*?*oseid=*
      Disallow: /collections/*sort_by*

      User-agent: adsbot-google
      Disallow: /checkout
    ROBOTS

    expect(allowed?(body)).to be(true)
  end

  it "disallows /products.json under a matching User-agent: * rule" do
    expect(allowed?("User-agent: *\nDisallow: /products.json\n")).to be(false)
    expect(allowed?("User-agent: *\nDisallow: /*.json\n")).to be(false)
    expect(allowed?("User-agent: *\nDisallow: /\n")).to be(false)
  end

  it "treats an empty Disallow as allow-all" do
    expect(allowed?("User-agent: *\nDisallow:\n")).to be(true)
  end

  it "lets the longest matching rule win, Allow winning a tie" do
    expect(allowed?("User-agent: *\nDisallow: /\nAllow: /products.json\n")).to be(true)
    expect(allowed?("User-agent: *\nAllow: /\nDisallow: /products\n")).to be(false)
  end

  it "honours $ as an end anchor" do
    expect(allowed?("User-agent: *\nDisallow: /products.json$\n", "/products.json")).to be(false)
    expect(allowed?("User-agent: *\nDisallow: /products.json$\n", "/products.json?page=1")).to be(true)
  end

  it "prefers a group naming this agent over the * group" do
    body = "User-agent: *\nDisallow: /\n\nUser-agent: portage-cli\nAllow: /\n"

    expect(allowed?(body)).to be(true)
  end

  it "reads grouped User-agent lines as one group, and ignores comments and other groups" do
    body = "# hello\nUser-agent: googlebot\nUser-agent: *\nDisallow: /products.json # no\n\n" \
           "User-agent: bingbot\nAllow: /\n"

    expect(allowed?(body)).to be(false)
  end
end
