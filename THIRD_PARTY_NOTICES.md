# Third-party code

- **AXe** (MIT, Copyright (c) 2025 Cameron Cooke) — `Sources/MiniRunSim/AXe/` contains files copied
  from https://github.com/cameroncooke/AXe at commit `30f4bfa9bc81817906a60fadedbc913d7314b7e1`
  (HID input, accessibility, orientation helpers), with minimal changes to drop the CLI layer.
  The full license is in `Sources/MiniRunSim/AXe/LICENSE-AXe`.
- **idb / FBSimulatorControl** (MIT, Copyright (c) Meta Platforms, Inc. and affiliates) — built
  from AXe's pinned fork by `scripts/build-frameworks.sh` and linked at runtime; not checked in.
- **WebRTC** (BSD 3-Clause, Copyright (c) 2011, The WebRTC project authors) — the prebuilt
  `WebRTC.framework` from https://github.com/stasel/WebRTC release `156.0.0` (M156), built from
  the official WebRTC source without changes. SwiftPM downloads it (pinned by checksum in
  `Package.swift`), and minirun.app ships it in `Contents/Frameworks`. The license text:

  > Copyright (c) 2011, The WebRTC project authors. All rights reserved.
  >
  > Redistribution and use in source and binary forms, with or without modification, are
  > permitted provided that the following conditions are met:
  >
  > - Redistributions of source code must retain the above copyright notice, this list of
  >   conditions and the following disclaimer.
  > - Redistributions in binary form must reproduce the above copyright notice, this list of
  >   conditions and the following disclaimer in the documentation and/or other materials
  >   provided with the distribution.
  > - Neither the name of Google nor the names of its contributors may be used to endorse or
  >   promote products derived from this software without specific prior written permission.
  >
  > THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND ANY EXPRESS
  > OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
  > MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE
  > COPYRIGHT HOLDER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL,
  > EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE
  > GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
  > AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
  > NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED
  > OF THE POSSIBILITY OF SUCH DAMAGE.

  libwebrtc includes further third-party code (BoringSSL, libyuv, libsrtp, usrsctp, and others)
  under their own permissive licenses; see https://webrtc.googlesource.com/src/+/refs/heads/main/LICENSE
  and the `third_party` folders of the WebRTC source.
