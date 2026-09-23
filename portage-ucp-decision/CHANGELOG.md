# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

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
