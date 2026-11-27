> [!IMPORTANT]
> **This is the Lattice fork of matrix-rust-rtc** (Lattice was called InterCom until November 2026, and the names in
> the code and of the builds still say so), the RTC core of
> [Lattice for Android](https://github.com/c4g7-dev/InterCom#android). It is not an Element product and is not
> affiliated with, endorsed by or supported by Element. Please report problems with this fork at
> <https://github.com/c4g7-dev/InterCom/issues>, not upstream. Below the "InterCom changes" section is the upstream
> README, kept for reference.

## InterCom changes

Branch `intercom`, based on the upstream tag `v0.5.0`. Nothing is published to a Maven repository:
`scripts/build-intercom-android.sh` builds the media variant for arm64-v8a and puts
`io.element.android:matrix-rtc-android:0.5.0-intercom.5` into `~/.m2`, where InterCom's fork of element-call-android
resolves it. It needs rustup with the `aarch64-linux-android` target, `cargo-ndk`, the Android NDK and a JDK.

What differs from `v0.5.0`:

- `0.5.0-intercom.5`: **a DM call can outlive the other person's leave.** `CallKind::Direct` gains
  `stay_when_alone` (`FfiCallKind.Direct.stayWhenAlone` in Kotlin, which every caller now states). With it the
  DM lifecycle does not end as `OthersLeft` when everyone else has left: the call stays in `InCall`, connected and
  alone, takes the other person back if they return, and ends when the host leaves it. The Android library uses
  that to count down before it leaves. A call found empty at the join still ends as `Empty`, and without the flag
  nothing changes.
- `0.5.0-intercom.4`: **a room-state join publishes on a transport with a JWT service.** Of the homeserver's
  advertised `livekit` transports, the first that names a `livekit_service_url` is taken, and the first at all only
  when none does (MSC keeps the homeserver's order). Synapse lists `m.livekit` with an SFU `url` alone first in
  `matrix_rtc.transports`, and the Rust SDK's bindings hand both entries over as `livekit`, so the join took the
  SFU `url`, whose token only MSC4195 `get_token` gives; the bindings have no `get_token`, and every native call
  was given up the moment its media connected. The legacy entry's token comes from `/sfu/get`, as Element Call
  web's does, and it is the focus that generation's peers can subscribe to.
- `0.5.0-intercom.3`: **a DM call whose own media connection is given up says so.** The leave that a lost
  connection issues ends the DM lifecycle as `Left` before the loss is reported, and that `Left` was taken as the
  call's end: a DM call whose token or SFU connection failed ended as `Left`, which the call screen closes without a
  word, typically half a second after it opened, with the ringback just started. `Left` from the DM lifecycle no
  longer ends the call's status (every way a participation ends reports its own end), so the call ends as
  `ConnectionClosed` with its reason, and the call screen says the connection was lost and why.
- `0.5.0-intercom.2`: the Android library names no directory of the machine it was built on (source paths are
  mapped to `/intercom-matrix-rust-rtc`, `/cargo` and `/rustup`), and it has a soname, `libmatrix_rtc_ffi.so`. The
  build script checks it. No change to the code that runs.
- **The encoding of an audio publication can be chosen.** `PublishOptions` gains `audio_encoding`
  (`AudioEncodingOptions`: a bitrate cap, stereo, DTX, RED), and `FfiPublishOptions` an optional `audio_encoding`
  (`FfiAudioEncoding`; `audioEncoding` in Kotlin). Left out, a track is published exactly as before, with livekit's
  defaults: 48 kbit/s, one channel, DTX and RED on. InterCom asks for stereo at 160 kbit/s without DTX or RED for the
  audio of a screen share, and for nothing on the microphone. `crates/matrix-rtc-livekit/src/audio_encoding.rs` says
  what each field does on the way to the Opus encoder.
- **The `livekit` crate is a patched copy**, `vendor/livekit` (0.9.7), because the published one cannot announce a
  stereo track and decodes a received stereo track to mono. The patch is `vendor/livekit-0.9.7-intercom.patch`;
  `vendor/README.md` explains it.
- **A received screen share's audio is delivered in two channels** (`ScreenShareAudio`); every other audio stream in
  one, as before.
- For every call, whatever is published: the answer to the SFU's offer repeats `stereo=1` on the audio sections
  where the offer has it. An answer to an offer without a stereo section is not touched.

The Kotlin bindings are generated from the build, so they carry the new record; the library's exported symbols are
those of 0.5.0 plus that record's metadata. Not built here: iOS, the web binding, and the other Android ABIs.

Tests: `cargo test -p matrix-rtc-transport -p matrix-rtc-livekit --lib`, `cargo test -p matrix-rtc-ffi --features
media --lib`, and the patch's own as `vendor/README.md` says. None of it has been run against an SFU.

---

# matrix-rust-rtc

[![License: AGPL-3.0 OR Element Commercial](https://img.shields.io/badge/License-AGPL_3.0_OR_Element_Commercial-blue.svg)](LICENSE)

> **Note:** This project is developed with AI assistance.

<p align="center">
  <img src="img/matrix-rust-rtc-icon.svg" height="300">
</p>

A Rust implementation of a Matrix RTC (Real-Time Communication) client SDK:
MSC4143 call-membership signalling, per-participant media-key exchange, and a
**transport-agnostic media layer** — one Rust codebase behind Kotlin/Swift
bindings (UniFFI) and a signalling-only WebAssembly build for the web.

## The call SDK layer

The centrepiece of the project. To the host, a call is a set of
**participants with observable frame streams** (microphone, camera,
screenshare) plus per-stream **constraints** (visibility, rendered size,
low-bandwidth mode). Everything underneath is hidden in Rust:

- **No LiveKit types on the API surface.** LiveKit is one implementation of
  the `MediaTransport` trait (`crates/matrix-rtc-transport`); future transports
  (P2P, WebTransport) slot into the same model.
- **MSC4195 multi-SFU built in**: each member publishes to their own focus
  and the connection pool (`matrix-rtc-transport`) maintains one connection
  per distinct focus in the call, with backoff, roster union, and identity
  mapping — so Kotlin/Swift never reimplement it.
- **Constraints drive simulcast subscribe-side**: tell the engine how a tile
  is rendered and it picks the right layer, pauses off-screen streams, and
  re-applies settings across reconnects.
- **Frame E2EE throughout**: media keys are exchanged over Olm-encrypted
  to-device messages and applied per participant across all connections.

```rust,no_run
let client = RtcClient::new(Arc::new(SdkMatrixBackend::new(matrix_sdk_client)));
let room = client.room(room_id, RoomOptions::default()).await?;
room.seeded().await;

let call = room.join_call(CallJoinOptions::new().slot("standup")).await?; // m.call#standup

// Key exchange, the engine, and the connection to our own focus.
let media = attach_livekit(
    &call,
    room.backend().clone(),
    LiveKitAttachOptions {
        format: Default::default(), // must match RoomOptions::format
        http: None,
        auto_subscribe: true,
        stability: Default::default(),
    },
)
.await?
.media;

let camera = media
    .engine
    .publish(PublishOptions::camera(VideoSourceConfig { width: 1280, height: 720 }))
    .await?;

// `capture_video` is synchronous and latest-frame-wins: a plain thread does.
let (frames, mut ffmpeg) = ffmpeg_frames("clip.mp4")?; // examples/publish_video.rs
std::thread::spawn(move || {
    for frame in frames {
        // Errors once the publication is gone (left, slot closed, ...).
        if camera.capture_video(frame).is_err() {
            break;
        }
    }
});

// Receive: one task per remote camera, logging what arrives. Ctrl-C
// leaves; the loop ends when the call's status says it ended, which a leave,
// the slot or the room closing all produce.
let engine = media.engine;
let mut events = engine.subscribe_events();
let mut status = call.subscribe_status();
let hang_up = tokio::signal::ctrl_c();
tokio::pin!(hang_up);
let mut left = false;
loop {
    let event = tokio::select! {
        _ = &mut hang_up, if !left => {
            left = true;
            call.leave(Default::default()).await?;
            continue;
        }
        ended = status.wait_for(|status| matches!(status, CallStatus::Ended { .. })) => {
            println!("call ended: {:?}", ended.map(|status| status.clone()));
            break;
        }
        event = events.recv() => event,
    };
    match event {
        Ok(CallEvent::StreamStarted {
            member_id,
            kind: MediaStreamKind::Camera,
        }) => {
            let Some(mut frames) = engine
                .remote_track(&member_id, MediaStreamKind::Camera)
                .and_then(|track| track.video_frames())
            else {
                continue;
            };
            // How the tile is rendered: the engine picks the simulcast
            // layer that fits, and pauses the stream while not visible.
            engine.set_constraints(
                &member_id,
                MediaStreamKind::Camera,
                MediaConstraints {
                    detail: VideoDetail::Dimensions(Dimensions {
                        width: 320,
                        height: 180,
                    }),
                    ..Default::default()
                },
            );

            println!("{member_id}: camera started");
            tokio::spawn(async move {
                let mut received = 0u64;
                while let Some(frame) = frames.next().await {
                    // A real host renders `frame.buffer`'s I420 planes here.
                    received += 1;
                    if received.is_multiple_of(100) {
                        let (w, h) = (frame.buffer.width, frame.buffer.height);
                        println!("{member_id}: {received} frames, now {w}x{h}");
                    }
                }
            });
        }
        Ok(_) | Err(RecvError::Lagged(_)) => {}
        Err(RecvError::Closed) => break,
    }
}
ffmpeg.kill()?;
```

[`examples/publish_video.rs`](crates/matrix-rtc-call-sdk/examples/publish_video.rs)
is this sample as a runnable program, login and sync included. `LiveKitCall::join(&room, LiveKitCallOptions)`
does the client → room → call → attach steps in one call over a `matrix_sdk::Room`.

The same model crosses the FFI boundary — on Android/Kotlin (media-enabled
build, see below):

```kotlin
val room = client.room(roomId, FfiRoomOptions())
val call = room.joinCall(params)
val session = connectMediaSession(call, config)
val stream = session.videoStream(memberId, FfiStreamKind.CAMERA)!!
while (true) {
    val frame = stream.next() ?: break
    // safe copy: frame.data(plane) — or zero-copy while holding the frame:
    // frame.planePtr(plane) / frame.stride(plane) / frame.planeLen(plane)
}
```

Audio frames cross by value; video frames are handles with both safe-copy and
zero-copy plane access, latest-frame-wins so slow consumers drop frames
instead of lagging. See [ARCHITECTURE.md](ARCHITECTURE.md) for the full
design, the module docs in `crates/matrix-rtc-ffi/src/media/mod.rs` for the
host-app integration flow, and
[crates/matrix-rtc-call-sdk/README.md](crates/matrix-rtc-call-sdk/README.md)
for a runnable two-client example against the local backend.

## Workspace crates

- `crates/matrix-rtc-transport`: how media flows, for any MatrixRTC
  application on the core — the `MediaTransport` contract, frames,
  constraints, the media key handler, the MSC4195 multi-SFU connection pool
  (`pool`), and the pure MSC4195 control plane (`livekit`). No transport IO,
  **no LiveKit client**; compiles for wasm32.
- `crates/matrix-rtc-call-sdk`: the call SDK hosts use — the call's media
  model over that contract (participants, tiles, the unified event stream,
  the `CallEngine`), `attach_media`, and
  behind features `attach_livekit` and the high-level `LiveKitCall::join`
  facade with the examples and e2e test. Fully unit-tested against a fake
  transport.
- `crates/matrix-rtc-livekit`: MSC4195 LiveKit transport — SFU token exchange,
  per-participant frame E2EE, and the `MediaTransport` implementation. Knows no
  call. Native-only (pulls in `libwebrtc`).
- `crates/matrix-rtc-core`: the per-room MSC4143 core (`BaseRtcRoom`, a
  `SlotSession` per slot), the MSC4143/MSC4354 event conversion boundary, and
  the feeder that subscribes through a host's `MatrixBackend` and feeds it
  (`BaseRtcClient` opens rooms that feed themselves), and `compat`, the
  pre-2026 MatrixRTC membership formats Element Call still speaks.
- `crates/matrix-rtc-call`: the host-facing objects (`RtcClient` → `RtcRoom` →
  `RtcSession`/`RtcCall`) and the call application — reactions, raised hand,
  MSC4075 ringing — and the transport choice. No Matrix SDK,
  so it tests in seconds against no git dependencies.
- `crates/matrix-rtc-matrix-sdk`: `SdkMatrixBackend`, the `MatrixBackend` over
  matrix-rust-sdk. **No LiveKit**.
- `crates/matrix-rtc-ffi`: UniFFI-based Kotlin/Swift bindings — the
  client → room → call objects always, plus the call SDK's media
  (`matrix-rtc-call-sdk` with LiveKit) behind the `media` cargo feature
  (default off, keeps the slim artifact libwebrtc-free).
- `crates/matrix-rtc-wasm`: wasm bindings for the web (signalling only —
  browsers keep using livekit-js for media).
- `web`: browser-first JavaScript package and wasm-pack build/test scaffold.
- `mobile/android`: Gradle library module for the AAR; `Package.swift` +
  `Sources/MatrixRtc` (repo root): the Swift package over the released
  xcframework; `mobile/ios`: its local-development manifest and build output.
- `demo/backend`: self-contained MatrixRTC backend (Synapse +
  lk-jwt-service + **two** LiveKit SFUs for multi-focus testing, docker
  compose) used by the e2e call test on CI and for local development.

## Releases

Tagged releases (`v*`) ship the media variant for both platforms; see
[RELEASING.md](RELEASING.md) for how they are cut and
[mobile/PACKAGING.md](mobile/PACKAGING.md#consuming-a-release) for the full
integration notes.

```kotlin
// Android — Gradle (GitHub Packages Maven repository, or Maven Central once enabled)
implementation("io.element.android:matrix-rtc-android:<version>")
```

```
// iOS — Xcode: File > Add Package Dependencies…, this repository's URL, a v* tag.
// Then add -ObjC to the app target's "Other Linker Flags".
```

## Quick Mobile Builds

To build the Android AAR and iOS XCFramework with one command each:

```bash
# Prerequisites (the bindings generator is the in-repo uniffi-bindgen crate)
cargo install cargo-ndk

# Add required Rust targets
rustup target add aarch64-apple-ios aarch64-apple-ios-sim x86_64-apple-ios
rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android

# Slim (signalling-only) artifacts
./scripts/build-android-aar.sh
./scripts/build-ios-xcframework.sh

# Media-enabled artifacts (frame streams + publishing; statically links libwebrtc)
make build-android-media
make build-ios-media
```

See [mobile/PACKAGING.md](mobile/PACKAGING.md) for detailed documentation —
including what changes with the media variant (binary sizes, `libwebrtc.jar`
on Android, the required `-ObjC` linker flag on iOS), integration guides, and
CI/CD setup. [mobile/README.md](mobile/README.md) covers what a host app has to
do (native loading, logging, keep-alive, diagnosing dead media), and
[CHANGELOG.md](CHANGELOG.md) tracks what changed for integrators — read its
Breaking section before bumping the SDK.

## Quick Web Builds

```bash
cd web
npm run build
npm run test:vitest
```

The `web/` package uses `wasm-pack` to generate browser-first bindings under `web/pkg/`.

## Manual Binding Generation

If you prefer to generate bindings manually without building the full AAR/XCFramework:

```bash
cargo build -p matrix-rtc-ffi --release

# Generate Swift bindings
uniffi-bindgen generate \
  --library target/release/libmatrix_rtc_ffi.dylib \
  --language swift \
  --out-dir ./bindings/swift

# Generate Kotlin bindings
uniffi-bindgen generate \
  --library target/release/libmatrix_rtc_ffi.so \
  --language kotlin \
  --out-dir ./bindings/kotlin
```

## Basic commands

```bash
cargo check
cargo fmt --check
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

End-to-end call test against the local backend stack — two clients exchange
E2EE-encrypted tone audio and pattern video, in both single-focus and
two-foci (multi-SFU) scenarios, including a constraints pause/resume pass
(see [demo/backend/README.md](demo/backend/README.md); also run by CI on
every PR):

```bash
make backend-up
make test-e2e
```

The media FFI smoke tests (no backend needed, compiles libwebrtc):

```bash
make test-ffi-media
```

## Pre-commit checklist

Before committing any change, run:

```bash
cargo check
cargo fmt
cargo clippy --all-targets --all-features -- -D warnings
cargo test
```

Then run binding tasks when relevant:

- If changes touch `crates/matrix-rtc-wasm/**` or `web/**`:

```bash
cd web && npm run build
cd web && npm run test:vitest
```

- If changes touch `crates/matrix-rtc-ffi/**`, `mobile/**`, or `scripts/build-*.sh`:

```bash
./scripts/build-android-aar.sh
./scripts/build-ios-xcframework.sh
```

(`./scripts/build-ios-xcframework.sh` is macOS-only; add `MEDIA=1` when the
change touches the media feature.)

If a required platform/toolchain is not available locally, document the skip reason in the PR description and ensure the corresponding CI job passes before merge.

Finally, record anything a host integrator would notice in
[CHANGELOG.md](./CHANGELOG.md) — new or changed API, behaviour changes, and
especially breaking changes to the command-sender callbacks, which surface as
compile errors in the host app.

## Copyright & License

Copyright (c) 2026 Element Creations Ltd.

This software is dual licensed by Element Creations Ltd (Element). It can be used either:

(1) for free under the terms of the GNU Affero General Public License (as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any later version); OR

(2) under the terms of a paid-for Element Commercial License agreement between you and Element (the
terms of which may vary depending on what you and Element have agreed to).

Unless required by applicable law or agreed to in writing, software distributed under the Licenses is
distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
implied. See the Licenses for the specific language governing permissions and limitations under the
Licenses.

See [LICENSE](LICENSE) and [LICENSE-COMMERCIAL](LICENSE-COMMERCIAL).
