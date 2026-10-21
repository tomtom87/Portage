# MCP Registry image for the buyer server, io.github.tomtom87/portage: portage mcp over stdio.
# Mount your records at /root/.portage: -v "$HOME/.portage:/root/.portage". Hand-off prints
# the checkout link, since a container can't open your browser. portage-cli 0.14.0 must be on
# RubyGems before this builds.
FROM ruby:3.4-slim
LABEL io.modelcontextprotocol.server.name="io.github.tomtom87/portage"
ENV PORTAGE_HANDOFF_TARGET=print
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && gem install --no-document portage-cli:0.14.0 \
 && apt-get purge -y build-essential && apt-get autoremove -y && rm -rf /var/lib/apt/lists/*
ENTRYPOINT ["portage", "mcp"]
