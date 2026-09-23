#!/usr/bin/env python3
"""Starting-point bridge script for ModelBackends::Laya.

Reads the same {"state", "questions"} JSON on stdin that ModelBackends::Jev
sends over HTTP, runs it through Laya (huggingface.co/convaiinnovations/laya),
and writes {"answers"} JSON to stdout — the contract Laya#ask expects back.

Point LAYA_BRIDGE_SCRIPT at a copy of this file (or your own script following
the same contract):

    export LAYA_BRIDGE_SCRIPT=/path/to/laya_bridge.py
    pip install laya  # or: transformers, per huggingface.co/convaiinnovations/laya

This file is not exercised by this gem's own test suite — it depends on the
`laya` package, which isn't a Ruby-gem dependency. Treat it as a template.
"""
import json
import sys

from laya import load  # pip install laya


def main():
    request = json.loads(sys.stdin.read())
    model = load()  # router mode auto-detects language/checkpoint

    answers = model.ask(state=request["state"], questions=request["questions"])
    # `model.ask` is expected to return, per question name, something with
    # type/confidence/value fields — adjust this mapping to whatever the
    # installed `laya` version's return shape actually is.
    json.dump({"answers": answers}, sys.stdout)


if __name__ == "__main__":
    main()
