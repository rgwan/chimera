# Vendored cocotb extensions

PEP-420 namespace package `cocotbext`: no `__init__.py` at this level, so
`cocotbext.axi` and `cocotbext.jtag` resolve as separate importable subtrees.
`cocotb_bus` is taken from nixpkgs, not vendored.

## cocotbext.axi
- version: 0.1.28
- upstream: https://github.com/alexforencich/cocotbext-axi (tag `v0.1.28`)
- commit: 1c0365e261dc5563f7eabb7fd327f2b9dee895de
- license: MIT (`axi/LICENSE`, Copyright (c) 2020-2025 Alex Forencich)
- subtree sha256: f78f6ced82d0a9dbfa3eae5cac780363a18d3a8fd8ec3d42f8da50c549253539

## cocotbext.jtag
- version: 0.4.0
- upstream: https://github.com/daxzio/cocotbext-jtag (tag `v0.4.0`)
- commit: c8f6e9c556cce8cca1f8c29af28bcc5ea8da79bc
- license: MIT (`jtag/LICENSE`, Copyright (c) 2024-2026 Daxzio; upstream ships
  the MIT text as the module docstring header, extracted here verbatim)
- subtree sha256 (excl. added LICENSE):
  a0cec805976b1539ca9f59e2d93babd1c37942637be4de1ffbbd82aac3bc55fa

Only the importable package subtree is kept (upstream tests, docs, and packaging
metadata are dropped).
