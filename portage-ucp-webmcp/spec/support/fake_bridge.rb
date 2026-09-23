# In-memory Bridge: a page's registered tools as a Hash, each answered by a
# block. Records every execute_tool call so specs can assert the exact input
# a tool received.
class FakeBridge
  attr_reader :calls, :list_count

  def initialize
    @tools = {}
    @calls = []
    @list_count = 0
  end

  def register(name, properties: {}, &handler)
    @tools[name] = { "name" => name, "description" => name,
                     "inputSchema" => { "type" => "object", "properties" => properties },
                     "handler" => handler || ->(_input) { {} } }
    self
  end

  def list_tools
    @list_count += 1
    @tools.values.map { |tool| tool.except("handler") }
  end

  def execute_tool(name, input)
    @calls << { name: name, input: input }
    @tools.fetch(name)["handler"].call(input)
  end
end
