# Changelog

All notable changes to this project are documented here. Format loosely follows
[Keep a Changelog](https://keepachangelog.com/en/1.0.0/); this project is
pre-1.0, so APIs may still shift between minor versions.

## [0.1.2] - 2026-09-16

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.7`
  so this gem can install alongside `portage-ucp` 0.7.0 (the pessimistic
  `~> 0.6` pin published with 0.1.1 excludes it).

## [0.1.1] - 2026-09-15

- No behavior change — widens the `portage-ucp` dependency pin to `~> 0.6`
  so this gem can install alongside `portage-ucp` 0.6.0 (the pessimistic
  `~> 0.5` pin published with 0.1.0 excludes it).

## [0.1.0] - Unreleased

- Initial pre-release. Wix adapter against the Stores (catalog) and eCommerce
  (cart, checkout, order) REST APIs.
