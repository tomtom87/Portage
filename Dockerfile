# MCP Registry image: a read-only Shopify catalog server over stdio.
# See script/mcp-stdio.rb for the env vars it needs.
FROM ruby:3.4-slim
LABEL io.modelcontextprotocol.server.name="io.github.tomtom87/portage"
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && gem install --no-document portage-ucp:0.16.0 portage-ucp-shopify:0.6.1 \
 && apt-get purge -y build-essential && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
COPY script/mcp-stdio.rb /app/server.rb
ENTRYPOINT ["ruby", "/app/server.rb"]
