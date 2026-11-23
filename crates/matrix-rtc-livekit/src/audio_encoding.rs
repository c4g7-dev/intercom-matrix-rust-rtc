// Copyright 2026 Element Creations Ltd.
//
// SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
// Please see LICENSE in the repository root for full details.

//! Maps the transport-neutral audio publish settings ([`AudioEncodingOptions`])
//! onto livekit's `TrackPublishOptions` (InterCom).
//!
//! What each field does on the way to the Opus encoder:
//!
//! - `max_bitrate_bps` becomes the sender's `RtpEncodingParameters.max_bitrate`,
//!   which libwebrtc takes as the encoder's target. Left out, livekit uses its
//!   speech-and-music default of 48 kbit/s.
//! - `stereo` is announced in the `AddTrackRequest`; the SFU then answers with
//!   `stereo=1` for the track, which is what makes libwebrtc encode two
//!   channels. This is the one setting the published livekit crate has no
//!   field for, hence the patched copy in `vendor/livekit`.
//! - `dtx` off is announced as `disable_dtx`, and the SFU leaves `usedtx=1`
//!   out of its answer.
//! - `red` off is announced as `disable_red`. With frame encryption on, as in
//!   every Matrix call, livekit never uses RED anyway.

use livekit::options::{AudioEncoding, TrackPublishOptions};
use livekit::prelude::TrackSource;
use matrix_rtc_transport::AudioEncodingOptions;

/// The livekit publish options for an audio publication.
///
/// With [`AudioEncodingOptions::default`] this is `TrackPublishOptions` as it
/// comes, with only the source set: what every audio track was published with
/// before the encoding could be chosen.
pub(crate) fn audio_publish_options(
    source: TrackSource,
    encoding: AudioEncodingOptions,
) -> TrackPublishOptions {
    TrackPublishOptions {
        source,
        audio_encoding: encoding
            .max_bitrate_bps
            .map(|max_bitrate| AudioEncoding { max_bitrate }),
        stereo: encoding.stereo,
        dtx: encoding.dtx,
        red: encoding.red,
        ..Default::default()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn defaults_are_livekits_own() {
        let ours = audio_publish_options(TrackSource::Microphone, AudioEncodingOptions::default());
        let theirs = TrackPublishOptions {
            source: TrackSource::Microphone,
            ..Default::default()
        };
        assert_eq!(ours.source, theirs.source);
        assert!(ours.audio_encoding.is_none() && theirs.audio_encoding.is_none());
        assert_eq!(ours.dtx, theirs.dtx);
        assert_eq!(ours.red, theirs.red);
        assert_eq!(ours.stereo, theirs.stereo);
        // And those are: silence suppressed, redundancy on, one channel.
        assert!(ours.dtx && ours.red && !ours.stereo);
    }

    #[test]
    fn music_is_stereo_at_the_given_rate_without_dtx_or_red() {
        let options = audio_publish_options(
            TrackSource::ScreenshareAudio,
            AudioEncodingOptions::music(160_000),
        );
        assert_eq!(options.source, TrackSource::ScreenshareAudio);
        assert_eq!(
            options.audio_encoding.map(|encoding| encoding.max_bitrate),
            Some(160_000)
        );
        assert!(options.stereo);
        assert!(!options.dtx);
        assert!(!options.red);
    }

    #[test]
    fn a_music_bitrate_is_kept_within_128_and_192_kbit() {
        let rate = |bps| {
            audio_publish_options(TrackSource::ScreenshareAudio, AudioEncodingOptions::music(bps))
                .audio_encoding
                .map(|encoding| encoding.max_bitrate)
        };
        assert_eq!(rate(48_000), Some(128_000));
        assert_eq!(rate(128_000), Some(128_000));
        assert_eq!(rate(192_000), Some(192_000));
        assert_eq!(rate(510_000), Some(192_000));
    }

    #[test]
    fn each_field_is_carried_on_its_own() {
        let options = audio_publish_options(
            TrackSource::Microphone,
            AudioEncodingOptions {
                max_bitrate_bps: Some(32_000),
                stereo: false,
                dtx: false,
                red: true,
            },
        );
        assert_eq!(
            options.audio_encoding.map(|encoding| encoding.max_bitrate),
            Some(32_000)
        );
        assert!(!options.stereo && !options.dtx && options.red);
    }
}
