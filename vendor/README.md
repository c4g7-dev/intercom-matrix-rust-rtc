# vendor

## livekit

`livekit/` is the `livekit` crate 0.9.7 as published on crates.io (Apache-2.0,
<https://github.com/livekit/rust-sdks>, commit `ead3a6936e7e526c6853255e2a731ba7648dd63d`,
path `livekit`), with `livekit-0.9.7-intercom.patch` applied. The root `Cargo.toml` puts it in
place of the registry crate with `[patch.crates-io]`. `Cargo.toml.orig`, `Cargo.lock` and
cargo's own bookkeeping files of the published crate are left out.

The patch does two things, neither of which the published crate has a setting for:

1. **A stereo audio publication.** `TrackPublishOptions` gains `stereo` (default `false`). When
   set, the `AddTrackRequest` of an audio track carries `stereo = true` and the `TF_STEREO`
   audio feature. A LiveKit SFU then answers with `stereo=1` for that track, which is what makes
   libwebrtc's Opus encoder send two channels. Without it a two-channel source is encoded mono.
2. **Stereo kept on a received track.** The answer to the SFU's offer (the subscriber
   connection) repeats `stereo=1` on the Opus `a=fmtp` line of every audio section whose
   counterpart in the offer has it. libwebrtc answers with its own Opus parameters, which never
   say stereo, and decodes such a section to one channel otherwise. An answer to an offer
   without a stereo section is left byte for byte as libwebrtc made it; an answer that no longer
   parses after the change is dropped in favour of the original.

To check that nothing else differs:

```sh
curl -L https://crates.io/api/v1/crates/livekit/0.9.7/download | tar -xz -C /tmp
diff -ru /tmp/livekit-0.9.7/src vendor/livekit/src       # what the patch file holds
```

Unit tests of the patch: in `vendor/livekit`, with a copy of the root `Cargo.lock` beside it,
`cargo test --lib stereo`.
