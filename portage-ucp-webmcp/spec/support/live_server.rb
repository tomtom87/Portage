# A real HTTP server for a Rack app, for specs that drive an actual browser
# against it (Ferrum can't navigate to an in-process Rack::MockRequest the
# way NodeBrowser's fetch relay can). A small WEBrick servlet translating to
# and from a Rack env, rather than `Rack::Handler::WEBrick` — Rack 3 dropped
# its built-in handlers into the separate `rackup` gem, not a dependency
# here for one spec. Only loaded by the :real_browser spec that needs it.
class LiveServer
  def initialize(app)
    require "webrick"
    require "stringio"

    @app = app
    @server = ::WEBrick::HTTPServer.new(
      Port: 0, BindAddress: "127.0.0.1",
      Logger: ::WEBrick::Log.new(File::NULL), AccessLog: []
    )
    @server.mount_proc("/") { |req, res| respond(req, res) }
    @thread = Thread.new { @server.start }
    Timeout.timeout(5) { sleep 0.01 until @server.status == :Running }
  end

  def base_url
    "http://127.0.0.1:#{@server.config[:Port]}"
  end

  def stop
    @server.shutdown
    @thread.join
  end

  private

  def respond(req, res)
    status, headers, body = @app.call(rack_env(req))
    res.status = status
    headers.each { |name, value| res[name] = value }
    res.body = body.enum_for(:each).to_a.join
  end

  def rack_env(req)
    env = {
      "REQUEST_METHOD" => req.request_method, "SCRIPT_NAME" => "", "PATH_INFO" => req.path,
      "QUERY_STRING" => req.query_string.to_s, "SERVER_NAME" => "127.0.0.1",
      "SERVER_PORT" => @server.config[:Port].to_s, "rack.version" => [1, 3], "rack.url_scheme" => "http",
      "rack.input" => StringIO.new(req.body.to_s), "rack.errors" => $stderr,
      "rack.multithread" => true, "rack.multiprocess" => false, "rack.run_once" => false
    }
    req.each { |field, value| env["HTTP_#{field.upcase.tr('-', '_')}"] = value }
    env["CONTENT_TYPE"] = req.content_type if req.content_type
    env["CONTENT_LENGTH"] = req.content_length.to_s if req.content_length
    env
  end
end
