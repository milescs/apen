#!/usr/bin/env bash
# Builds Apen from source and installs it as a regular app in /Applications.
#
#   ./scripts/install.sh               build, install to /Applications/Apen.app, and open it
#   ./scripts/install.sh --build-only  build without installing
#   ./scripts/install.sh --adhoc       don't use an Apple Development certificate even if one exists
set -euo pipefail

cd "$(dirname "$0")/.."
BUILD_ONLY=0
ADHOC=0
for arg in "$@"; do
  case "$arg" in
    --build-only) BUILD_ONLY=1 ;;
    --adhoc) ADHOC=1 ;;
    *) echo "Unknown option: $arg"; exit 64 ;;
  esac
done

step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
fail() { printf '\n\033[31mError:\033[0m %s\n' "$1" >&2; exit 1; }

step "Checking requirements"
[[ "$(uname -m)" == "arm64" ]] || fail "Apen needs a Mac with Apple silicon (M1 or later)."
macos_major="$(sw_vers -productVersion | cut -d. -f1)"
(( macos_major >= 26 )) || fail "Apen needs macOS 26 (Tahoe) or later; this Mac has $(sw_vers -productVersion)."
developer_dir="$(xcode-select -p 2>/dev/null || true)"
if [[ "$developer_dir" != *".app/Contents/Developer" ]]; then
  fail "Xcode is required (the Command Line Tools alone aren't enough).
Install Xcode 26 or later from the App Store, open it once, then run:
  sudo xcode-select -s /Applications/Xcode.app"
fi
xcode_major="$(xcodebuild -version 2>/dev/null | awk '/^Xcode/ {split($2, v, "."); print v[1]}')"
[[ -n "$xcode_major" ]] || fail "xcodebuild didn't run. Open Xcode once to finish its setup (or run: sudo xcodebuild -runFirstLaunch)."
(( xcode_major >= 26 )) || fail "Apen needs Xcode 26 or later; found Xcode $xcode_major."
echo "Apple silicon · macOS $(sw_vers -productVersion) · Xcode $(xcodebuild -version | awk 'NR==1 {print $2}')"

step "Checking XcodeGen"
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || fail "XcodeGen is required. Install Homebrew (https://brew.sh) and rerun, or install XcodeGen from https://github.com/yonaskolb/XcodeGen."
  brew install xcodegen
fi
echo "XcodeGen $(xcodegen --version | awk '{print $2}')"

step "Choosing a code signature"
if [[ -f Config/Local.xcconfig ]]; then
  echo "Using Config/Local.xcconfig"
elif (( ADHOC == 0 )) && identity="$(security find-identity -v -p codesigning 2>/dev/null | grep -m1 '"Apple Development' | sed -E 's/.*"(.*)"/\1/')" && [[ -n "$identity" ]]; then
  team="$(security find-certificate -c "$identity" -p 2>/dev/null | openssl x509 -noout -subject 2>/dev/null | sed -nE 's/.*OU ?= ?([A-Z0-9]{10}).*/\1/p')"
  if [[ -n "$team" ]]; then
    printf 'DEVELOPMENT_TEAM = %s\nCODE_SIGN_IDENTITY = Apple Development\n' "$team" > Config/Local.xcconfig
    echo "Signing with your Apple Development certificate (team $team); macOS keeps Apen's permissions across updates."
  else
    echo "Couldn't read the team from your certificate; building with an ad-hoc signature."
  fi
else
  echo "Building with an ad-hoc signature. After each rebuild, macOS may ask you to re-enable Accessibility for Apen."
  echo "(Tip: sign in to Xcode with your Apple ID under Xcode › Settings › Accounts to get a free certificate, then rerun.)"
fi

if (( BUILD_ONLY )); then
  step "Building Apen (first build downloads Swift packages; this takes a few minutes)"
  make release
  echo "Built: $PWD/build/DerivedData/Build/Products/Release/Apen.app"
  exit 0
fi

step "Building and installing Apen (first build downloads Swift packages; this takes a few minutes)"
make install
printf '\n\033[1mApen is installed in /Applications and running in your menu bar.\033[0m\n'
echo "The welcome window walks you through microphone access, Accessibility and the one-time model download."
