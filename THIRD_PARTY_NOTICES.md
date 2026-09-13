# Snake third-party notices

Snake-authored source code is licensed under Apache-2.0; see the root
`LICENSE` and `NOTICE`. That license applies only to Snake-authored files
and does not replace the terms of third-party components.

## Vendored source

| Component | Pinned source | License and retained notice |
| --- | --- | --- |
| Bonsplit | [almonk/bonsplit@77b9cce](https://github.com/almonk/bonsplit/tree/77b9ccebf1c6e6533c3df1030b5efa9a3db2f351) | MIT; see `Vendor/Bonsplit/LICENSE` (Copyright © 2026 Alasdair Monk) |
| SwiftTerm | [migueldeicaza/SwiftTerm@v1.13.0](https://github.com/migueldeicaza/SwiftTerm/tree/8e7a1e154f470e19c709a00a8768df348ba5fc43) | MIT; see `Vendor/SwiftTerm/LICENSE`, including xterm.js and SourceLair copyright notices |
| Tokyo Night Day / Night palettes | [folke/tokyonight.nvim@cdc07ac](https://github.com/folke/tokyonight.nvim/tree/cdc07ac78467a233fd62c493de29a17e0cf2b2b6) | Folke Lemaitre; root Apache-2.0 LICENSE retained in `Vendor/TokyoNight/LICENSE`. Original generated palette headers also identify MIT; see the preserved files and provenance README. |

`Vendor/Bonsplit` contains Snake-specific modifications. They are recorded in
`Vendor/Bonsplit/CHANGES-SNAKE.md`; its upstream MIT license and copyright
notice remain intact.

## Rust core and native libraries

The Rust source is resolved from the pinned `Rust/snake_core/Cargo.lock` when
building a release. The following direct components, their transitive native
libraries, and their license obligations must accompany any distributed binary:

| Component | Version/source | License |
| --- | --- | --- |
| rusqlite / libsqlite3-sys / SQLite | `rusqlite 0.32.1`, bundled SQLite | MIT for the Rust bindings; SQLite is public domain |
| ssh2 / libssh2-sys / libssh2 | `ssh2 0.9.6` | MIT OR Apache-2.0 |
| OpenSSL / openssl-sys | vendored through `ssh2` | Apache-2.0 |
| serde, serde_json, sha2, thiserror, uuid, zeroize and normal dependencies | pinned in `Cargo.lock` | MIT OR Apache-2.0 unless their package metadata states otherwise |
| UniFFI family | `uniffi 0.29.5` | Mozilla Public License 2.0 |

For source releases, Cargo obtains each Rust crate from its pinned registry
source, which includes that crate's license text. For an application or binary
release, package the exact resolved dependency notices and license texts next
to the executable. Canonical texts: [Apache-2.0](https://www.apache.org/licenses/LICENSE-2.0),
[MIT](https://spdx.org/licenses/MIT.html), [MPL-2.0](https://www.mozilla.org/MPL/2.0/),
and [SQLite public-domain dedication](https://www.sqlite.org/copyright.html).

MPL-2.0 applies to the UniFFI files themselves and modifications to those
files; it does not change the Apache-2.0 license of independent Snake source
files. See the [Mozilla MPL FAQ](https://www.mozilla.org/en-US/MPL/2.0/FAQ/).

## Release checks

- Preserve all notices above and the vendored MIT `LICENSE` files.
- Generate a fresh Cargo license inventory from `Cargo.lock` for each binary
  release; do not assume a development-only crate ships in the final product.
- Do not publish credentials, private keys, signing material, build outputs,
  nested Git metadata, or the excluded internal design prototype.
