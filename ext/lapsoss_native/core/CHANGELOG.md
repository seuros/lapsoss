# Changelog

## 0.2.0 (2026-10-21)


### ⚠ BREAKING CHANGES

* require CRuby 4.0 and the native extension; admitted captures now return event IDs instead of threads or synchronous nil.

### Features

* share a Rust dispatcher between the gem and embedded apps ([#10](https://github.com/seuros/lapsoss/issues/10)) ([31df414](https://github.com/seuros/lapsoss/commit/31df4142545a60d506e0db47ea91fa7dc3b58248))
