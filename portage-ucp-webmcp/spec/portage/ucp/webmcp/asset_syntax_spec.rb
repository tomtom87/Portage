require "spec_helper"
require "open3"
require "tmpdir"

# Every page script parses, in the exact form the gem hands a browser.
# assets/autofill.js once shipped with `*/` inside its header comment, which
# closed the comment early; every real Autofill.call raised SyntaxError while
# the specs stayed green, because they stubbed the bridge's #autofill and
# never parsed the real file (design-log §51). A browser never sees these
# files on their own: consumer.js and autofill.js are function expressions
# ScriptEvaluator wraps as `(<src>)(...)`, and polyfill.js/registrar.js are
# scripts Registrar#to_js concatenates and fills in. So each one is checked
# as that final expression, via `node --check`.
RSpec.describe "WebMCP page script syntax" do
  evaluated_as = {
    "autofill.js" => lambda {
      Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.autofill_expression({ "email" => "a@example.com" },
                                                                         { "email" => "input[name='email']" })
    },
    "consumer.js" => -> { Portage::Ucp::WebMcp::Bridges::ScriptEvaluator.expression("execute", "t", { "a" => 1 }) },
    "polyfill.js" => -> { Portage::Ucp::WebMcp.polyfill_js },
    "registrar.js" => lambda {
      Portage::Ucp::WebMcp::Registrar.new(catalog: Store.catalog(only: %w[search_catalog]), endpoint: "/e",
                                          include_polyfill: true).to_js
    }
  }.freeze

  before { skip "node isn't on PATH — can't parse the page scripts" unless NodeBrowser.available? }

  def node_check(source)
    Dir.mktmpdir do |dir|
      path = File.join(dir, "evaluated.js")
      File.write(path, source)
      Open3.capture2e("node", "--check", path)
    end
  end

  it "knows how every file in assets/ is evaluated, so a new asset can't skip this check" do
    expect(Dir.children(Portage::Ucp::WebMcp::Assets::DIR).grep(/\.js\z/).sort).to eq(evaluated_as.keys.sort)
  end

  evaluated_as.each do |name, expression|
    it "parses #{name} as the browser receives it" do
      output, status = node_check(instance_exec(&expression))

      expect(status).to be_success, "#{name} doesn't parse:\n#{output}"
    end
  end

  it "catches a comment closed early, the way autofill.js once was" do
    _output, status = node_check("(/*\n * from PORTAGE_SHIP_*/buyer context\n */\nfunction () {})")

    expect(status).not_to be_success
  end
end
