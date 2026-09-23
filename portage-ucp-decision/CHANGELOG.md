# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [Unreleased]

- **A backend failure could escape as a raw exception.** Jev let
  `Faraday::Error`, `JSON::ParserError` (a non-JSON 2xx) and `KeyError` (no
  `answers`) through, Laya let `Errno::ENOENT` (a missing
  `LAYA_INFER_COMMAND`) and `KeyError` through, and `ConfidenceGate` raised
  `KeyError` for an unanswered question. All are now `BackendError`, with
  one shared `ModelBackends.parse_answers` for both backends' replies.
- **Neither backend had a timeout.** Jev could stall a checkout for about two
  minutes on a hung connection, and Laya forever. Jev now gives up after 5s
  to connect and 15s to answer. Laya kills its bridge after `timeout:`
  (default 60s).
- `LAYA_PYTHON=/opt/venv/bin/python` (a path, not a bare name) was always
  reported as "isn't on PATH", so the backend never counted as configured.
- `examples/laya_bridge.py` returned `type`/`confidence`/`value`, which the
  Ruby side doesn't read, so every noul through it held the purchase. It
  now emits the per-type keys (`noul`, `choice`, `score`).
- `Jev#configuration_problem` joins `Laya#configuration_problem` (now
  public): the reason a backend can't answer yet, for a setup check.

## [0.1.0] - 2026-09-23

- First skeleton: `OfferRanking`, `EscalationPolicy`, `ConfidenceGate`, and
  `PolicyCheck` as typed decisions, per
  `docs/plans/system-one-decision-layer.md`.
- `ConfidenceGate.via_backend` gates on what the model answered, not only on
  how sure it was. Checked live against Jev:
  - A noul (the default type) crashed with `NoMethodError` on every call,
    because Jev sends no `confidence` for a noul. A noul now gates on its
    yes-probability.
  - A choice or score proceeded on any confident answer, a confident
    "escalate" included (Jev answered `escalate` at 0.99 for a live
    `requires_escalation` checkout). These now need `proceed_on:` (an
    option, or a Range of score levels), and proceed only on a match.
- `ModelBackends::Jev` falls back to `TYPESAFE_API_KEY`, the name TypeSafe's
  own docs use, when `JEV_API_KEY` isn't set.
