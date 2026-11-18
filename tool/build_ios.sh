#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'HELP'
XMPlus iOS build (macOS + Xcode + CocoaPods + Flutter 3.47.9+)

Usage: tool/build_ios.sh [ipa|device|simulator] [options]
  ipa                   Build an unsigned Release IPA (default; for LiveContainer)
  device                Alias for ipa
  simulator             Build and zip a Debug simulator .app
  --output-dir DIR      Artifact directory (default: outputs/ios)
  --build-name X.Y.Z     Override version without editing pubspec.yaml
  --build-number N       Override build number without editing pubspec.yaml
  --skip-pub            Use already resolved dependencies
  -h, --help            Show this help

FLUTTER_BIN may point to a Flutter executable. Otherwise use the repository's
Temp/flutter SDK when present, then flutter on PATH. No signing, upload or
installation is performed. Only lib/main.dart is built. Logs live in Temp/.

Examples:
  ./tool/build_ios.sh
  ./tool/build_ios.sh ipa --build-name 1.2.4 --build-number 17
  FLUTTER_BIN=/path/to/flutter/bin/flutter ./tool/build_ios.sh
HELP
}
fail() { printf 'Error: %s\n' "$*" >&2; exit 1; }
MODE=ipa
OUTPUT_DIR=outputs/ios
SKIP_PUB=false
BUILD_OPTIONS=()
if [[ $# -gt 0 && "$1" != -* ]]; then MODE="$1"; shift; fi
case "$MODE" in ipa|device|simulator) ;; *) usage >&2; exit 2 ;; esac
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --output-dir)
      [[ $# -ge 2 && -n "$2" ]] || fail '--output-dir requires a directory'
      OUTPUT_DIR="$2"; shift 2 ;;
    --build-name)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || fail '--build-name must be X.Y.Z'
      BUILD_OPTIONS+=(--build-name "$2"); shift 2 ;;
    --build-number)
      [[ $# -ge 2 && "$2" =~ ^[0-9]+$ ]] || fail '--build-number must be numeric'
      BUILD_OPTIONS+=(--build-number "$2"); shift 2 ;;
    --skip-pub) SKIP_PUB=true; shift ;;
    *) fail "Unknown option: $1 (use --help)" ;;
  esac
done
ROOT="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT"
[[ "$(uname -s)" == Darwin ]] || fail 'iOS builds require macOS and full Xcode'
for command in xcrun xcodebuild pod python3 ditto; do
  command -v "$command" >/dev/null || fail "Missing prerequisite: $command"
done
xcrun --sdk iphoneos --show-sdk-path >/dev/null || fail 'Select full Xcode with xcode-select'
if [[ -z "${FLUTTER_BIN:-}" ]]; then
  if [[ -x "$ROOT/Temp/flutter/bin/flutter" ]]; then
    FLUTTER_BIN="$ROOT/Temp/flutter/bin/flutter"
  else
    FLUTTER_BIN="$(command -v flutter || true)"
  fi
fi
[[ -n "$FLUTTER_BIN" ]] || fail 'Flutter not found; install Flutter or set FLUTTER_BIN'
FLUTTER_BIN="$(command -v "$FLUTTER_BIN" || true)"
[[ -x "$FLUTTER_BIN" ]] || fail 'FLUTTER_BIN is not an executable'
FLUTTER_BIN="$(python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$FLUTTER_BIN")"
DART_BIN="$(dirname "$FLUTTER_BIN")/cache/dart-sdk/bin/dart"
STAMP="$(date '+%Y-%m-%d_%H-%M-%S')"
LOG_DIR="$ROOT/Temp/ios-build-$STAMP-$$"
mkdir -p "$LOG_DIR" "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
LOCK="$ROOT/Temp/.ios-build.lock"
mkdir "$LOCK" 2>/dev/null || fail "Another build owns $LOCK. If its process has ended, remove that stale lock before retrying."
printf '%s\n' "$$" > "$LOCK/pid"
cleanup() { rm -f "$LOCK/pid"; rmdir "$LOCK"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
run_step() {
  local label="$1"; shift
  printf '\n[%s]\n' "$label"
  if ! "$@" 2>&1 | tee "$LOG_DIR/$label.log"; then
    fail "$label failed; see $LOG_DIR/$label.log"
  fi
}
"$FLUTTER_BIN" --version --machine > "$LOG_DIR/flutter-version.json"
python3 - "$LOG_DIR/flutter-version.json" <<'PY'
import json, re, sys
version = json.load(open(sys.argv[1]))['frameworkVersion']
match = re.match(r'(\d+)\.(\d+)\.(\d+)', version)
if not match or tuple(map(int, match.groups())) < (3, 47, 9):
    sys.exit(f'Flutter {version} is too old; use Flutter 3.47.9 or newer. Tested: 3.47.9.')
print(f'Flutter {version}')
PY
[[ -x "$DART_BIN" ]] || fail "Dart SDK not found beside $FLUTTER_BIN"
if [[ "$SKIP_PUB" == false ]]; then
  run_step dependencies "$FLUTTER_BIN" pub get --enforce-lockfile
elif [[ ! -f .dart_tool/package_config.json ]]; then
  fail '--skip-pub requires existing dependencies; run without --skip-pub first'
fi
run_step analyze "$DART_BIN" analyze lib
run_step method-trace "$DART_BIN" --packages=.dart_tool/package_config.json tool/check_method_trace.dart
# Bash 3.2 on macOS treats an empty array as unset under nounset.
if [[ "$MODE" == simulator ]]; then
  run_step build "$FLUTTER_BIN" build ios --simulator --debug --no-pub -t lib/main.dart ${BUILD_OPTIONS[@]+"${BUILD_OPTIONS[@]}"}
  APP_PATH="$ROOT/build/ios/iphonesimulator/Runner.app"
  VARIANT=simulator
else
  run_step build "$FLUTTER_BIN" build ios --release --no-codesign --no-pub -t lib/main.dart ${BUILD_OPTIONS[@]+"${BUILD_OPTIONS[@]}"}
  APP_PATH="$ROOT/build/ios/iphoneos/Runner.app"
  VARIANT=unsigned
fi
run_step package python3 tool/package_ios.py --app "$APP_PATH" --variant "$VARIANT" --output-dir "$OUTPUT_DIR" --temp-dir "$LOG_DIR" --stamp "$STAMP"
printf '\nArtifacts: %s\nLogs: %s\n' "$OUTPUT_DIR" "$LOG_DIR"
