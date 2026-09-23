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

    # `model.ask` is a placeholder: adapt this call to whatever the installed
    # `laya` version actually exposes. Only the output shape below is fixed.
    raw = model.ask(state=request["state"], questions=request["questions"])

    # ModelBackends.parse_answers reads the answer from a key named after its
    # type, the same wire shape Jev returns:
    #   noul   -> {"type": "noul", "noul": <probability of yes, 0.0..1.0>}
    #   choice -> {"type": "choice", "choice": <option>, "confidence": <0.0..1.0>}
    #   score  -> {"type": "score", "score": <level>, "confidence": <0.0..1.0>}
    # A noul without "noul" holds every purchase ConfidenceGate is asked about.
    answers = {}
    for name, question in request["questions"].items():
        kind = question["type"]
        answers[name] = {"type": kind, kind: raw[name]["value"], "confidence": raw[name].get("confidence")}
    json.dump({"answers": answers}, sys.stdout)


if __name__ == "__main__":
    main()
