#!/bin/bash
# Copyright 2026 Element Creations Ltd.
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial
# Please see LICENSE in the repository root for full details.

set -euo pipefail

# Build InterCom's core for Android and publish it to the local Maven
# repository (~/.m2) as io.element.android:matrix-rtc-android:<version>,
# where element-call-android's build looks for it.
#
#   scripts/build-intercom-android.sh [version]
#
# The version defaults to INTERCOM_VERSION below, which is the one
# element-call-android's gradle/libs.versions.toml names (`matrix_rtc`).
#
# arm64-v8a only: it is the one ABI InterCom for Android is released for. The
# media variant, the release profile and split debug info, as upstream's
# release workflow builds it. Needs rustup with the aarch64-linux-android
# target, cargo-ndk, the Android NDK (ANDROID_NDK_HOME or ANDROID_HOME/ndk)
# and a JDK.

INTERCOM_VERSION="0.5.0-intercom.1"
VERSION="${1:-$INTERCOM_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# The library carries the source path of every panic message. Name them by what they are rather than by where this
# machine keeps them, so that the result does not depend on, or tell, the builder's directories. Two paths stay as
# they are, which rustc does not write: the linker's own output path and the file name of cxx's C++ source.
CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
export RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$PROJECT_ROOT=/intercom-matrix-rust-rtc --remap-path-prefix=$CARGO_HOME_DIR=/cargo --remap-path-prefix=$HOME=/home/build"

# One ABI in the AAR: a library left over from another build would be packaged too.
rm -rf mobile/android/matrixrtc/src/main/jniLibs

MEDIA=1 scripts/build-android-aar.sh --target aarch64-linux-android --profile mobile-release --split-debug

(cd mobile/android && ./gradlew --no-daemon :matrixrtc:publishReleasePublicationToMavenLocal \
    -PmatrixRtcMedia=true "-PmatrixRtcVersion=$VERSION")

echo "Published io.element.android:matrix-rtc-android:$VERSION (arm64-v8a) to ~/.m2."
