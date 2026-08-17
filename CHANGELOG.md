# Changelog

## [1.0.0](https://github.com/seuros/lapsoss/compare/lapsoss/v0.4.12...lapsoss/v1.0.0) (2026-08-17)


### ⚠ BREAKING CHANGES

* drop Rails 8.0 support, require Rails 8.1+
* drop Rails 7.2 support (EOL), require Rails 8.0+

### Features

* add Lapsoss.silence for block-scoped capture suppression ([337675a](https://github.com/seuros/lapsoss/commit/337675ab5fd50c1f6094cf6f341afc2068f5c129))
* drop Rails 7.2 support (EOL), require Rails 8.0+ ([de46daf](https://github.com/seuros/lapsoss/commit/de46daf78f52043e5a87a77be83a7334db484da4))
* drop Rails 8.0 support, require Rails 8.1+ ([d2aa0c3](https://github.com/seuros/lapsoss/commit/d2aa0c35d8b1cb0533e10fcd5d545e85826b20b6))
* record Rails 8.1 structured events (Rails.event) as breadcrumbs ([751df68](https://github.com/seuros/lapsoss/commit/751df68f32482f5e63394bff868560353f2b2322))


### Bug Fixes

* resolve test issues and update CI matrix versions ([#8](https://github.com/seuros/lapsoss/issues/8)) ([76c8a96](https://github.com/seuros/lapsoss/commit/76c8a9624417f503b9f5cc71056eeaa87a2aa3a6))

## [0.4.12](https://github.com/seuros/lapsoss/compare/lapsoss/v0.4.11...lapsoss/v0.4.12) (2025-12-08)


### Features

* add OpenObserve adapter for observability platform integration ([#5](https://github.com/seuros/lapsoss/issues/5)) ([dccab97](https://github.com/seuros/lapsoss/commit/dccab97408e844d9b4ad67bb205d15b001b59f8e))
* add OTLP adapter for OpenTelemetry Protocol support ([#7](https://github.com/seuros/lapsoss/issues/7)) ([7d96240](https://github.com/seuros/lapsoss/commit/7d96240fd9582564015d5b8a34f84ae97c3b7b48))

## [0.4.11](https://github.com/seuros/lapsoss/compare/lapsoss/v0.4.10...lapsoss/v0.4.11) (2025-11-24)


### Features

* add adapter endpoint isolation and enhanced scrubbing ([#3](https://github.com/seuros/lapsoss/issues/3)) ([f197e97](https://github.com/seuros/lapsoss/commit/f197e97541742e1c0c9158127221319ebc1eb9ab))

## [0.4.10](https://github.com/seuros/lapsoss/compare/lapsoss-v0.4.9...lapsoss/v0.4.10) (2025-11-24)


### Bug Fixes

* add backtrace frame correctly ([cfe509d](https://github.com/seuros/lapsoss/commit/cfe509d1e76af8297aa501fceaeb18f378763cdc))
* add fallback methods. ([6eb6f84](https://github.com/seuros/lapsoss/commit/6eb6f848a9603f15f4eeda63b8778443bafed908))
* add release-please automation ([2485f39](https://github.com/seuros/lapsoss/commit/2485f397a26806981e3f990d130eb0773e82ada3))
* avoid dups ([3d66aba](https://github.com/seuros/lapsoss/commit/3d66abaae40b1ee82e1d45d870cd4889c6060342))
* remove deprecated ActiveSupport::Configurable (Rails 8.2) ([c1ff1ae](https://github.com/seuros/lapsoss/commit/c1ff1ae594af923f4aa7a989074e013faddd6203))
* remove deprecated ActiveSupport::Configurable (Rails 8.2) ([784f8e8](https://github.com/seuros/lapsoss/commit/784f8e8df311d551c2d32c0020892cda66192030))
* remove Rails.logger dependencies from runtime code ([f83d0b1](https://github.com/seuros/lapsoss/commit/f83d0b112420f2005ce7b4d6b3ed62aaefeeb327))
* resolve integration build failures ([41c66b9](https://github.com/seuros/lapsoss/commit/41c66b93c6dfe55b2b8e471f690177d120b3f4c6))
