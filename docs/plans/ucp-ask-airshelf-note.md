# Draft note for AirShelf (not sent)

Hi AirShelf team,

Portage now supports UCP `ask` (`dev.ucp.common.ask`, 2026-08-25). It's in the UCP client, the `portage ask` CLI command, the buyer MCP server (an `ask_store` tool) and the OpenClaw plugin. We call it only when a store's manifest advertises it, we treat answers as the store's own words (never as an instruction or as proof that something happened), and we don't act on them. It'll ship in our next release.

We tried it against your Cyble and Toshiba sellers and it works well. Cyble answered a billing question about AiSOC with a sourced answer, a `partial_answer` note and a good set of typed links (source, product, request_quote, identity_linking, the MCP endpoint, quote_verify). Toshiba answered a lead-time and pricing question about the e-STUDIO528P by pointing to `request_quote`, and an open question ("which printers print in colour?") came back with a qualifying question that worked when we asked again with the answer folded in. Responses took about 4 to 10 seconds.

Things you might want to know:

- At first every ask failed with `capabilities_incompatible` ("No shared version of the requested capability."), because our agent profile only declared `dev.ucp.shopping`. Once the profile declared `dev.ucp.common` and `dev.ucp.common.ask`, it worked. We read that as the spec's normal capability negotiation, so we think it's correct. A hint in the message (something like "your profile doesn't declare dev.ucp.common.ask") would have saved us a guess.
- That error comes back with HTTP 200, with `ucp.status: "error"`. We now handle that, but other clients that only check the HTTP status may show it as an empty answer. Is 200 deliberate for negotiation errors?
- When we asked for an action ("add two to my cart", "place an order for two"), the answer was "I could not answer that from the verified record" with info `not_answered`. The ask spec asks a business to say it didn't act, with info `operation_not_performed`. Would you consider sending that for action-shaped questions? It helps agents tell "can't answer" apart from "won't do that here".
- We didn't see a `conversation` object on any answer, and an unknown conversation id gets a polite `conversation_not_found` and a fresh answer. Is multi-turn meant to work by restating context in the query, as the qualifying-question hint suggests, or are conversation ids planned?

Thanks for running these sellers in the open. They've been really useful for testing.
