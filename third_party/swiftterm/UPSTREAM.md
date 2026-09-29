# SwiftTerm 1.5.0

Local source snapshot used by the Agentbox macOS terminal.

- Upstream: https://github.com/migueldeicaza/SwiftTerm
- Tag: `1.5.0`
- License: MIT, see `LICENSE`

The upstream package manifest includes an unrelated `termcast` executable and
`swift-argument-parser` dependency. This local manifest builds only the
`SwiftTerm` library so the macOS app can build without network access.
