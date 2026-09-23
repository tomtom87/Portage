require "spec_helper"

RSpec.describe Portage::Ucp::WebMcp::Bridges::ScriptEvaluator do
  def evaluator_returning(value)
    expressions = []
    evaluator = described_class.new(evaluate: lambda { |expression|
      expressions << expression
      value
    })
    [evaluator, expressions]
  end

  it "evaluates the consumer script with the operation, tool name and input as JSON literals" do
    evaluator, expressions = evaluator_returning('{"ok":true,"value":{"id":"o1"}}')

    expect(evaluator.execute_tool("get_order", { "order_id" => "o1" })).to eq("id" => "o1")
    expect(expressions.last).to start_with("(#{Portage::Ucp::WebMcp::Assets.read('consumer.js')})")
    expect(expressions.last).to end_with('("execute", "get_order", {"order_id":"o1"})')
  end

  it "lists tools" do
    evaluator, = evaluator_returning('{"ok":true,"value":[{"name":"search_catalog"}]}')

    expect(evaluator.list_tools).to eq([{ "name" => "search_catalog" }])
  end

  it "accepts a driver that already parsed the envelope into a Hash" do
    evaluator, = evaluator_returning({ "ok" => true, "value" => [] })

    expect(evaluator.list_tools).to eq([])
  end

  it "raises BridgeError when the page has no WebMCP surface" do
    evaluator, = evaluator_returning('{"ok":false,"code":"no_surface","error":"no WebMCP tool surface"}')

    expect { evaluator.list_tools }.to raise_error(Portage::Ucp::WebMcp::BridgeError, /no WebMCP/)
  end

  it "raises ToolNotFoundError for a tool the page doesn't register" do
    evaluator, = evaluator_returning('{"ok":false,"code":"not_registered","error":"not registered: x"}')

    expect { evaluator.execute_tool("x", {}) }.to raise_error(Portage::Ucp::WebMcp::ToolNotFoundError)
  end

  it "raises ServerError when the tool itself fails, like a tool error over any other transport" do
    evaluator, = evaluator_returning('{"ok":false,"code":"execute_failed","error":"network down"}')

    expect { evaluator.execute_tool("x", {}) }.to raise_error(Portage::Ucp::Client::ServerError, "network down")
  end

  it "wraps driver failures and unreadable envelopes in BridgeError" do
    failing = described_class.new(evaluate: ->(_) { raise IOError, "target closed" })
    garbled, = evaluator_returning("<html>")
    wrong_type, = evaluator_returning(42)

    expect { failing.list_tools }.to raise_error(Portage::Ucp::WebMcp::BridgeError, /IOError: target closed/)
    expect { garbled.list_tools }.to raise_error(Portage::Ucp::WebMcp::BridgeError, /invalid JSON/)
    expect { wrong_type.list_tools }.to raise_error(Portage::Ucp::WebMcp::BridgeError, /Integer/)
  end

  it "requires a callable" do
    expect { described_class.new(evaluate: "js") }.to raise_error(ArgumentError)
  end

  describe "driver adapters" do
    let(:envelope) { '{"ok":true,"value":[]}' }

    it "wraps Ferrum's evaluate_async with its resolve callback" do
      page = double("Ferrum::Page")
      expect(page).to receive(:evaluate_async).with(/\A\(.*\)\.then\(arguments\[0\]\)\z/m, 30).and_return(envelope)

      expect(described_class.ferrum(page).list_tools).to eq([])
    end

    it "wraps Playwright's evaluate as an arrow function" do
      page = double("Playwright::Page")
      expect(page).to receive(:evaluate).with(/\A\(\) => \(/).and_return(envelope)

      expect(described_class.playwright(page).list_tools).to eq([])
    end

    it "wraps Selenium's execute_async_script with its done callback" do
      driver = double("Selenium::WebDriver::Driver")
      expect(driver).to receive(:execute_async_script)
        .with(/\Avar done = arguments\[arguments.length - 1\]; \(.*\)\.then\(done\);\z/m).and_return(envelope)

      expect(described_class.selenium(driver).list_tools).to eq([])
    end
  end
end
