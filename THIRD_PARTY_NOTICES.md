# Third-Party Notices

MultiCompress vendors C sources from upstream compression libraries so the gem can build without system-level compression packages. MultiCompress's own Ruby code and extension glue are MIT-licensed, but vendored third-party sources keep their upstream licenses.

## Vendored native libraries

| Library | Vendored version | Vendored source scope | Upstream license used by MultiCompress |
|---|---:|---|---|
| Zstandard (`zstd`) | 1.5.7 | `lib/` | BSD side of upstream BSD OR GPLv2 licensing |
| LZ4 | 1.10.0 | `lib/` | BSD 2-Clause |
| Brotli | 1.2.0 | `c/common`, `c/enc`, `c/dec`, `c/include` | MIT |

## Notes

- Zstandard changed copyright wording from older Facebook/Yann Collet headers to `Meta Platforms, Inc. and affiliates` in newer releases. This is a copyright-owner notice change, not a prohibition on use.
- Do not imply that Facebook, Meta, Google, Yann Collet, or upstream contributors endorse MultiCompress.
- When distributing source or binary builds, keep the vendored source notices and this file in the package.
- LZ4's repository contains GPL-licensed areas outside `lib/`; MultiCompress vendors only `lib/`, which upstream documents as the BSD 2-Clause integration area.

## Upstream projects

- Zstandard: https://github.com/facebook/zstd
- LZ4: https://github.com/lz4/lz4
- Brotli: https://github.com/google/brotli
