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

INTERCOM_VERSION="0.5.0-intercom.3"
VERSION="${1:-$INTERCOM_VERSION}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
cd "$PROJECT_ROOT"

# The library carries the source path of every panic message. Name them by what they are rather than by where this
# machine keeps them, so that the result does not depend on, or tell, the builder's directories. When several
# prefixes match a path, rustc takes the last one given, so the most specific goes last. The C and C++ sources that
# crates compile (cxx's cxx.cc carries its own file name) get the same mapping through the compiler's flags, which
# cargo-ndk passes on, and crates/matrix-rtc-ffi/build.rs gives the library a soname, without which the linker
# writes its own output path into the version definitions. The script ends by checking the result.
CARGO_HOME_DIR="${CARGO_HOME:-$HOME/.cargo}"
RUSTUP_HOME_DIR="${RUSTUP_HOME:-$HOME/.rustup}"
REMAPS=("$HOME=/build" "$RUSTUP_HOME_DIR=/rustup" "$CARGO_HOME_DIR=/cargo" "$PROJECT_ROOT=/intercom-matrix-rust-rtc")
C_REMAP=""
for remap in "${REMAPS[@]}"; do
    RUSTFLAGS="${RUSTFLAGS:-} --remap-path-prefix=$remap"
    # Which of several matching prefixes clang takes has changed between its versions; each of them hides $HOME.
    C_REMAP="$C_REMAP -ffile-prefix-map=$remap"
done
export RUSTFLAGS
export CFLAGS_aarch64_linux_android="${CFLAGS_aarch64_linux_android:-}$C_REMAP"
export CXXFLAGS_aarch64_linux_android="${CXXFLAGS_aarch64_linux_android:-}$C_REMAP"

# One ABI in the AAR: a library left over from another build would be packaged too.
rm -rf mobile/android/matrixrtc/src/main/jniLibs

MEDIA=1 scripts/build-android-aar.sh --target aarch64-linux-android --profile mobile-release --split-debug

# No path of this machine in what is shipped: neither the home directory nor any /home/ at all.
BUILT_LIB="mobile/android/matrixrtc/src/main/jniLibs/arm64-v8a/libmatrix_rtc_ffi.so"
if LC_ALL=C grep -a -q -e "$HOME" -e "/home/" "$BUILT_LIB"; then
    echo "❌ $BUILT_LIB still names a directory of this machine:" >&2
    strings -a "$BUILT_LIB" | grep -e "$HOME" -e "/home/" | head -5 >&2
    exit 1
fi

(cd mobile/android && ./gradlew --no-daemon :matrixrtc:publishReleasePublicationToMavenLocal \
    -PmatrixRtcMedia=true "-PmatrixRtcVersion=$VERSION")

echo "Published io.element.android:matrix-rtc-android:$VERSION (arm64-v8a) to ~/.m2."
