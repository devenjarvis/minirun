# Third-party code

- **AXe** (MIT, Copyright (c) 2025 Cameron Cooke) — `Sources/MiniRunSim/AXe/` contains files copied
  from https://github.com/cameroncooke/AXe at commit `30f4bfa9bc81817906a60fadedbc913d7314b7e1`
  (HID input, accessibility, orientation helpers), with minimal changes to drop the CLI layer.
  The full license is in `Sources/MiniRunSim/AXe/LICENSE-AXe`.
- **idb / FBSimulatorControl** (MIT, Copyright (c) Meta Platforms, Inc. and affiliates) — built
  from AXe's pinned fork by `scripts/build-frameworks.sh` and linked at runtime; not checked in.
