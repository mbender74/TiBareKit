#!/usr/bin/env bash
# scripts/update-bare-kit.sh -- rebuild bare-kit prebuilds and install into TiBareKit.
#
# Mirrors the "Prebuild (maintainers)" flow from README.md, automated and
# parameterized. One correction vs. the README's manual loop: bare-make's
# --arch uses 'x64' for x86_64 (the cmake-toolchains files are named
# ios-x64-simulator.cmake, etc.), NOT 'x86_64'. The README's manual loop
# uses 'x86_64' which throws "No toolchain found for target 'ios-x86_64-simulator'".
# This script uses 'x64'.
#
# Usage:
#   scripts/update-bare-kit.sh --bare-kit /path/to/bare-kit [options]
#
# Options:
#   --bare-kit PATH       path to a bare-kit checkout (required)
#   --tibarekit PATH      TiBareKit repo root (default: this script's parent/..)
#   --platforms LIST      comma-separated subset of: ios,android,catalyst
#                         (default: ios,android,catalyst). catalyst requires ios;
#                         if catalyst is given without ios, ios is added automatically.
#   --no-install          skip `npm install` in bare-kit (assume deps present)
#   --verify              run `ti build --build-only` per platform after install
#   -h, --help            show this help
#
# Prereqs (checked at start; missing ones error out):
#   - CMake 4.0+, Xcode (xcodebuild), ninja (resolved via bare-make's deps)
#   - bare-make on PATH (npm install --global bare-make)
#   - Node.js + npm
#   - For android: ANDROID_HOME and ANDROID_NDK_HOME env vars set
#   - For --verify: ti CLI on PATH
#
# What each platform does:
#   ios       3 bare-make slices (arm64 device, arm64 sim, x64 sim) ->
#             lipo-combine simulators via `make ios/BareKit.xcframework` ->
#             copy to <tibarekit>/ios/platform/BareKit.xcframework (replaces).
#   catalyst  cmake with re-stamped toolchains (IOS/IOSSIMULATOR -> MACCATALYST
#             in LC_BUILD_VERSION via scripts/maccatalyst/toolchain_stamp.py) for
#             arm64 + x86_64, lipo into a universal framework, append as a 3rd
#             slice to the xcframework. Reuses the ios-x64-simulator prebuilds
#             for the x86_64 path, so ios MUST run first.
#   android   `./gradlew :bare-kit:assembleRelease` -> extract AAR ->
#             classes.jar -> android/lib/bare-kit.jar,
#             jni/<abi>/libbare-kit.so -> android/platform/android/jniLibs/<abi>/
#             for all 4 ABIs (arm64-v8a, armeabi-v7a, x86, x86_64).
set -euo pipefail

# ---------------------------------------------------------------------------
# helpers
# ---------------------------------------------------------------------------
info()  { printf '\033[1m[update-bare-kit]\033[0m %s\n' "$*"; }
warn()  { printf '\033[1;33m[update-bare-kit]\033[0m %s\n' "$*" >&2; }
die()   { printf '\033[1;31m[update-bare-kit]\033[0m %s\n' "$*" >&2; exit 1; }

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1${2:+ ($2)}"
}

# Resolve a glob to its first match, die if no match.
glob_first() {
  local pattern="$1" desc="$2"
  shopt -s nullglob
  local matches=($pattern)
  shopt -u nullglob
  if [ ${#matches[@]} -eq 0 ]; then
    die "no match for $desc ($pattern)"
  fi
  printf '%s' "${matches[0]}"
}

# ---------------------------------------------------------------------------
# defaults + arg parsing
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_TIBAREKIT="$(cd "$SCRIPT_DIR/.." && pwd)"

BARE_KIT=""
TIBAREKIT="$DEFAULT_TIBAREKIT"
PLATFORMS="ios,android,catalyst"
NO_INSTALL=0
VERIFY=0

show_help() {
  awk 'NR==1{next} /^set -euo pipefail$/{exit} {sub(/^# ?/,""); print}' "$0"
  exit 0
}

while [ $# -gt 0 ]; do
  case "$1" in
    --bare-kit)   BARE_KIT="$2"; shift 2;;
    --tibarekit)  TIBAREKIT="$2"; shift 2;;
    --platforms) PLATFORMS="$2"; shift 2;;
    --no-install) NO_INSTALL=1; shift;;
    --verify)     VERIFY=1; shift;;
    -h|--help)    show_help;;
    *) die "unknown arg: $1 (try --help)";;
  esac
done

[ -n "$BARE_KIT" ] || die "--bare-kit <path> is required (try --help)"
[ -d "$BARE_KIT" ] || die "--bare-kit path does not exist: $BARE_KIT"
[ -d "$TIBAREKIT" ] || die "--tibarekit path does not exist: $TIBAREKIT"
BARE_KIT="$(cd "$BARE_KIT" && pwd)"
TIBAREKIT="$(cd "$TIBAREKIT" && pwd)"

[ -f "$BARE_KIT/package.json" ]  || die "--bare-kit is not a bare-kit checkout (no package.json): $BARE_KIT"
[ -f "$BARE_KIT/CMakeLists.txt" ] || die "--bare-kit is not a bare-kit checkout (no CMakeLists.txt): $BARE_KIT"
[ -d "$TIBAREKIT/ios" ] || die "--tibarekit is not a TiBareKit checkout (no ios/ dir): $TIBAREKIT"
[ -d "$TIBAREKIT/android" ] || die "--tibarekit is not a TiBareKit checkout (no android/ dir): $TIBAREKIT"

# Parse + order platforms: ios before catalyst (catalyst reuses ios-x64-sim prebuilds).
IFS=',' read -ra PLAT_ARR <<< "$PLATFORMS"
DO_IOS=0; DO_ANDROID=0; DO_CATALYST=0
for p in "${PLAT_ARR[@]}"; do
  case "$p" in
    ios)      DO_IOS=1;;
    android)  DO_ANDROID=1;;
    catalyst) DO_CATALYST=1;;
    *) die "unknown platform in --platforms: $p (valid: ios,android,catalyst)";;
  esac
done
if [ "$DO_CATALYST" = 1 ] && [ "$DO_IOS" = 0 ]; then
  warn "catalyst requires ios -- adding ios to the build order"
  DO_IOS=1
fi

# ---------------------------------------------------------------------------
# prereq checks
# ---------------------------------------------------------------------------
require_cmd cmake "required for ios + catalyst"
require_cmd xcodebuild "required for ios + catalyst"
require_cmd ninja "required for ios + catalyst (or resolve via bare-make)"
require_cmd bare-make "required for ios (npm install --global bare-make)"
require_cmd python3 "required for catalyst re-stamp"
require_cmd npm "required for bare-kit npm install"
[ "$DO_ANDROID" = 1 ] && require_cmd ./gradlew "required for android (run from bare-kit root)"
[ "$DO_ANDROID" = 1 ] && require_cmd unzip "required for android AAR extraction"
[ "$VERIFY" = 1 ] && require_cmd ti "required for --verify (npm install --global titanium)"

if [ "$DO_ANDROID" = 1 ]; then
  [ -n "${ANDROID_HOME:-}" ] || die "ANDROID_HOME not set -- required for android build"
  [ -n "${ANDROID_NDK_HOME:-}" ] || die "ANDROID_NDK_HOME not set -- required for android build"
fi

NPM_ROOT_G="$(npm root -g)"
CMAKE_TOOLCHAINS="$NPM_ROOT_G/bare-make/node_modules/cmake-toolchains"
[ -d "$CMAKE_TOOLCHAINS" ] || die "cmake-toolchains not found at $CMAKE_TOOLCHAINS (reinstall bare-make?)"
NINJA_BIN="$(glob_first "$NPM_ROOT_G/bare-make/node_modules/ninja-runtime-darwin-*/bin/ninja" "ninja-runtime")"
MACOSX_SDK="$(xcrun --sdk macosx --show-sdk-path)"

info "bare-kit:    $BARE_KIT"
info "tibarekit:   $TIBAREKIT"
info "platforms:  $( [ $DO_IOS = 1 ] && printf 'ios ' )$( [ $DO_ANDROID = 1 ] && printf 'android ' )$( [ $DO_CATALYST = 1 ] && printf 'catalyst ' )"
info "toolchains: $CMAKE_TOOLCHAINS"
info "ninja:      $NINJA_BIN"
info "macosx sdk: $MACOSX_SDK"

# ---------------------------------------------------------------------------
# shared state
# ---------------------------------------------------------------------------
TMPDIR_RUN="$(mktemp -d -t update-bare-kit.XXXXXX)"
cleanup() { rm -rf "$TMPDIR_RUN"; }
trap cleanup EXIT

# ---------------------------------------------------------------------------
# build_ios: 3 bare-make slices -> lipo simulators -> xcframework -> install
# ---------------------------------------------------------------------------
build_ios() {
  info "=== iOS: 3 bare-make slices ==="
  cd "$BARE_KIT"

  # Order matters: x64-sim MUST be last so build/_deps/.../ios-x64-simulator
  # is left in place for the catalyst x86_64 path to copy from.
  local specs=("ios arm64" "ios arm64 --simulator" "ios x64 --simulator")
  for spec in "${specs[@]}"; do
    # shellcheck disable=SC2086
    set -- $spec
    local plat="$1" arch="$2" sim="${3:-}"
    info "  slice: $plat $arch $sim"
    rm -rf build
    bare-make generate --platform "$plat" --arch "$arch" ${sim:+$sim} --with-debug-symbols
    bare-make build
    local slice="$plat-$arch${sim:+-simulator}"
    mkdir -p "prebuilds/$slice"
    cp -a build/apple/BareKit.framework "prebuilds/$slice/BareKit.framework"
  done

  info "=== iOS: assemble xcframework ==="
  ( cd prebuilds && make ios/BareKit.xcframework )

  info "=== iOS: install into TiBareKit ==="
  rm -rf "$TIBAREKIT/ios/platform/BareKit.xcframework"
  cp -R "$BARE_KIT/prebuilds/ios/BareKit.xcframework" "$TIBAREKIT/ios/platform/BareKit.xcframework"
  info "  installed: $TIBAREKIT/ios/platform/BareKit.xcframework"
}

# ---------------------------------------------------------------------------
# build_catalyst: re-stamped toolchains for arm64 + x86_64 -> lipo -> append slice
# ---------------------------------------------------------------------------
build_catalyst() {
  info "=== Mac Catalyst: re-stamped toolchains ==="
  cd "$BARE_KIT"

  # Substitute placeholders in temp copies (do not mutate the originals).
  local tc_dir="$TMPDIR_RUN/tc"
  mkdir -p "$tc_dir"
  for arch in arm64 x86_64; do
    sed -e "s|<BARE_MAKE_CMAKE_TOOLCHAINS>|$CMAKE_TOOLCHAINS|g" \
        -e "s|<MACOSX_SDK>|$MACOSX_SDK|g" \
        "$TIBAREKIT/scripts/maccatalyst/ios-$arch-maccatalyst.cmake" \
        > "$tc_dir/ios-$arch-maccatalyst.cmake"
  done

  for arch in arm64 x86_64; do
    info "  catalyst $arch: configure"
    # Always clean -- incremental reconfigure does not pick up
    # CMAKE_*_LINKER_FLAGS_INIT changes, and the arm64 link fails without
    # the dynamic_lookup flag the toolchain sets.
    rm -rf "build-catalyst-$arch"
    cmake -S . -B "build-catalyst-$arch" -G Ninja \
      -DCMAKE_MAKE_PROGRAM="$NINJA_BIN" \
      -DCMAKE_TOOLCHAIN_FILE="$tc_dir/ios-$arch-maccatalyst.cmake" \
      -DCMAKE_BUILD_TYPE=RelWithDebInfo

    # x86_64 has no ios-x64 device prebuild -- copy the ios-x64-simulator
    # prebuilds (left in build/_deps/ by the ios step) into ios-x64/ first,
    # then reconfigure so find_library sees them.
    if [ "$arch" = "x86_64" ]; then
      local src
      src="$(glob_first "build/_deps/*/ios-x64-simulator" "ios-x64-simulator prebuilds (from ios step)")"
      local dep_root
      dep_root="$(glob_first "build-catalyst-x86_64/_deps/*" "bare-build dep dir")"
      local dst="$dep_root/ios-x64"
      mkdir -p "$dst"
      cp -a "$src"/libjs.a "$src"/libv8.a "$src"/libc++.a "$dst"/
      cmake -S . -B build-catalyst-x86_64  # reconfigure so find_library sees them
    fi

    info "  catalyst $arch: re-stamp prebuilds IOS/IOSSIMULATOR -> MACCATALYST"
    local dep_root
    dep_root="$(glob_first "build-catalyst-$arch/_deps/*" "bare-build dep dir")"
    python3 "$TIBAREKIT/scripts/maccatalyst/toolchain_stamp.py" \
      "$dep_root"/ios-*/libjs.a \
      "$dep_root"/ios-*/libv8.a \
      "$dep_root"/ios-*/libc++.a

    info "  catalyst $arch: build"
    cmake --build "build-catalyst-$arch" --target bare_kit --config RelWithDebInfo
    # If cmake re-fetched prebuilds (overwriting re-stamped ones), re-stamp + re-link.
    if ! python3 "$TIBAREKIT/scripts/maccatalyst/toolchain_stamp.py" \
        "$dep_root"/ios-*/libjs.a \
        "$dep_root"/ios-*/libv8.a \
        "$dep_root"/ios-*/libc++.a 2>/dev/null | grep -q "TOTAL patched: 0"; then
      warn "  catalyst $arch: prebuilds re-fetched by cmake -- re-stamping + re-linking"
      cmake --build "build-catalyst-$arch" --target bare_kit --config RelWithDebInfo
    fi
  done

  info "=== Mac Catalyst: lipo universal framework ==="
  local uni="$TMPDIR_RUN/BareKit.framework"
  rm -rf "$uni" && mkdir "$uni"
  cp -a build-catalyst-arm64/apple/BareKit.framework/ "$uni/"
  lipo -create \
    build-catalyst-arm64/apple/BareKit.framework/Versions/A/BareKit \
    build-catalyst-x86_64/apple/BareKit.framework/Versions/A/BareKit \
    -output "$uni/Versions/A/BareKit"

  info "=== Mac Catalyst: append slice to xcframework ==="
  local xcf="$TIBAREKIT/ios/platform/BareKit.xcframework"
  [ -d "$xcf/ios-arm64" ] || die "xcframework missing ios-arm64 slice -- run ios first"
  [ -d "$xcf/ios-arm64_x86_64-simulator" ] || die "xcframework missing simulator slice -- run ios first"
  local out="$TMPDIR_RUN/BareKit.xcframework"
  xcodebuild -create-xcframework \
    -framework "$xcf/ios-arm64/BareKit.framework" \
    -framework "$xcf/ios-arm64_x86_64-simulator/BareKit.framework" \
    -framework "$uni" \
    -output "$out"
  rm -rf "$xcf.old"
  mv "$xcf" "$xcf.old"
  mv "$out" "$xcf"
  rm -rf "$xcf.old"
  info "  installed: $xcf (3 slices: ios-arm64, simulator, maccatalyst)"
}

# ---------------------------------------------------------------------------
# build_android: gradle assembleRelease -> extract AAR -> install
# ---------------------------------------------------------------------------
build_android() {
  info "=== Android: gradlew :bare-kit:assembleRelease ==="
  cd "$BARE_KIT"
  ./gradlew :bare-kit:assembleRelease

  local aar="$BARE_KIT/android/build/outputs/aar/bare-kit-release.aar"
  [ -f "$aar" ] || die "AAR not produced at $aar"

  info "=== Android: extract AAR into TiBareKit ==="
  local extract="$TMPDIR_RUN/aar-extract"
  mkdir -p "$extract"
  unzip -o "$aar" -d "$extract" >/dev/null

  cd "$TIBAREKIT/android"
  rm -f lib/bare-kit.jar
  rm -rf platform/android/jniLibs
  cp "$extract/classes.jar" lib/bare-kit.jar
  mkdir -p platform/android/jniLibs
  for abi in arm64-v8a armeabi-v7a x86 x86_64; do
    [ -f "$extract/jni/$abi/libbare-kit.so" ] || die "AAR missing jni/$abi/libbare-kit.so"
    mkdir -p "platform/android/jniLibs/$abi"
    cp "$extract/jni/$abi/libbare-kit.so" "platform/android/jniLibs/$abi/"
  done
  info "  installed: android/lib/bare-kit.jar + jniLibs/{arm64-v8a,armeabi-v7a,x86,x86_64}/libbare-kit.so"
}

# ---------------------------------------------------------------------------
# verify_module: ti build --build-only per platform
# ---------------------------------------------------------------------------
verify_module() {
  local plat="$1"
  info "=== verify: ti build --build-only --platform $plat ==="
  case "$plat" in
    ios|catalyst)
      ( cd "$TIBAREKIT/ios" && ti build --build-only --sdk 13.3.0.GA --platform iphone )
      ;;
    android)
      ( cd "$TIBAREKIT/android" && ti build --build-only --sdk 13.3.0.GA --platform android )
      ;;
  esac
}

# ---------------------------------------------------------------------------
# main flow
# ---------------------------------------------------------------------------
cd "$BARE_KIT"
if [ "$NO_INSTALL" = 0 ]; then
  info "=== bare-kit: npm install (first time only) ==="
  npm install
fi

if [ "$DO_IOS" = 1 ]; then
  build_ios
fi

if [ "$DO_CATALYST" = 1 ]; then
  build_catalyst
fi

if [ "$DO_ANDROID" = 1 ]; then
  build_android
fi

if [ "$VERIFY" = 1 ]; then
  # The catalyst slice lives inside the ios xcframework, so a single ios
  # verify covers both. Don't verify ios twice when both are set.
  { [ "$DO_IOS" = 1 ] || [ "$DO_CATALYST" = 1 ]; } && verify_module ios
  [ "$DO_ANDROID" = 1 ] && verify_module android
fi

info "done."