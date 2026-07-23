require "spec_helper"

RSpec.describe UcpMcp::Adapter do
  subject(:adapter) { described_class.new }

  it "raises UcpMcp::NotImplementedError for every unoverridden capability method" do
    expect { adapter.search_catalog(query: "x", limit: 1) }.to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.get_product(product_id: "p") }.to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.get_cart(cart_id: "c") }.to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.add_line_item(cart_id: "c", product_id: "p", quantity: 1, idempotency_key: "k") }
      .to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.remove_line_item(cart_id: "c", line_item_id: "li", idempotency_key: "k") }
      .to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.create_checkout(line_items: [], idempotency_key: "k") }
      .to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.update_checkout(checkout_id: "c", updates: {}, idempotency_key: "k") }
      .to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.complete_checkout(checkout_id: "c", payment_token: "t", idempotency_key: "k") }
      .to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.get_order(order_id: "o") }.to raise_error(UcpMcp::NotImplementedError)
    expect { adapter.link_identity(oauth_token: "t") }.to raise_error(UcpMcp::NotImplementedError)
  end

  describe "capability advertisement (override detection)" do
    it "reports a method as NOT overridden on the base Adapter" do
      expect(described_class.instance_method(:search_catalog).owner).to eq(described_class)
    end

    it "reports a method as overridden on a subclass that implements it" do
      subclass = Class.new(described_class) do
        def search_catalog(query:, limit:) = []
      end
      expect(subclass.instance_method(:search_catalog).owner).to eq(subclass)
      expect(described_class.instance_method(:get_product).owner).to eq(described_class)
    end
  end
end
