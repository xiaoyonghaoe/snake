# Snake third-party notices

Snake-authored source code is licensed under Apache-2.0; see the root
`LICENSE` and `NOTICE`. That license applies only to Snake-authored files
and does not replace the terms of third-party components.

## Vendored source

| Component | Pinned source | License and retained notice |
| --- | --- | --- |
| Ghostty default palette (Snake Ghostty Clear adaptation) | [ghostty-org/ghostty@a2e4403](https://github.com/ghostty-org/ghostty/tree/a2e440396403385680008e456a741a7776091412) | MIT, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors; see `Vendor/TerminalThemes/LICENSE` and `README.md` for contrast adaptations. |
| Bonsplit | [almonk/bonsplit@77b9cce](https://github.com/almonk/bonsplit/tree/77b9ccebf1c6e6533c3df1030b5efa9a3db2f351) | MIT; see `Vendor/Bonsplit/LICENSE` (Copyright © 2026 Alasdair Monk) |
| SwiftTerm | [migueldeicaza/SwiftTerm@v1.13.0](https://github.com/migueldeicaza/SwiftTerm/tree/8e7a1e154f470e19c709a00a8768df348ba5fc43) | MIT; see `Vendor/SwiftTerm/LICENSE`, including xterm.js and SourceLair copyright notices |
| Tokyo Night Day / Night palettes | [folke/tokyonight.nvim@cdc07ac](https://github.com/folke/tokyonight.nvim/tree/cdc07ac78467a233fd62c493de29a17e0cf2b2b6) | Folke Lemaitre; root Apache-2.0 LICENSE retained in `Vendor/TokyoNight/LICENSE`. Original generated palette headers also identify MIT; see the preserved files and provenance README. |
| Catppuccin Latte / Mocha | [catppuccin/iterm@b2936a6](https://github.com/catppuccin/iterm/tree/b2936a6e55270fcc55421b1bb7d5fd194a489591) | MIT, Copyright (c) 2021 Catppuccin; see `Vendor/TerminalThemes/LICENSE` and `README.md`. |
| Gruvbox Light / Dark | [morhetz/gruvbox-contrib@150e9ca](https://github.com/morhetz/gruvbox-contrib/tree/150e9ca30fcd679400dc388c24930e5ec8c98a9f) | Original Gruvbox MIT/X11 by morhetz; see `Vendor/TerminalThemes/LICENSE` and `README.md`. |
| Solarized Light / Dark | [altercation/solarized@62f656a](https://github.com/altercation/solarized/tree/62f656a02f93c5190a8753159e34b385588d5ff3) | MIT, Copyright (c) 2011 Ethan Schoonover; see `Vendor/TerminalThemes/LICENSE` and `README.md`. |

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
| russh / russh-cryptovec / russh-util | `russh 0.64.1` | Apache-2.0 (crates omit the text; Snake ships it from `Resources/Licenses/Apache-2.0`) |
| russh-sftp | `russh-sftp 3.0.1` | Apache-2.0 |
| AWS-LC / aws-lc-rs / aws-lc-sys | `aws-lc-rs 1.18.2`, `aws-lc-sys 0.46.0` | ISC, Apache-2.0, MIT and BSD-3-Clause components as declared by the crates; the native `aws-lc/LICENSE` notices are collected |
| tokio, futures, hmac, sha1 and the RustCrypto stack | pinned in `Cargo.lock` | MIT OR Apache-2.0 unless their package metadata states otherwise |
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
