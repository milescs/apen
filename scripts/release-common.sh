# Shared settings for the release scripts. Values come from the environment or Config/Release.env
# (gitignored), e.g.:
#   APEN_TEAM_ID=ABCDE12345          # your paid Apple Developer team
#   APEN_ASC_KEY_ID=XXXXXXXXXX       # App Store Connect API key ID
#   APEN_ASC_ISSUER_ID=xxxxxxxx-...  # App Store Connect issuer ID
# The key itself stays in ~/.appstoreconnect/private_keys/AuthKey_<KEY_ID>.p8 and is never printed.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
[[ -f Config/Release.env ]] && source Config/Release.env
: "${APEN_TEAM_ID:?Set APEN_TEAM_ID (see scripts/release-common.sh)}"
: "${APEN_ASC_KEY_ID:?Set APEN_ASC_KEY_ID}"
: "${APEN_ASC_ISSUER_ID:?Set APEN_ASC_ISSUER_ID}"
APEN_ASC_KEY_PATH="${APEN_ASC_KEY_PATH:-$HOME/.appstoreconnect/private_keys/AuthKey_${APEN_ASC_KEY_ID}.p8}"
[[ -f "$APEN_ASC_KEY_PATH" ]] || { echo "Missing API key file: $APEN_ASC_KEY_PATH" >&2; exit 1; }

VERSION="$(awk -F' = ' '/^MARKETING_VERSION/ {print $2}' Config/Base.xcconfig)"
DIST=build/dist
mkdir -p "$DIST"
AUTH=(-allowProvisioningUpdates
      -authenticationKeyPath "$APEN_ASC_KEY_PATH"
      -authenticationKeyID "$APEN_ASC_KEY_ID"
      -authenticationKeyIssuerID "$APEN_ASC_ISSUER_ID")
# Distribution builds sign with automatic signing on the paid team (overrides Config/Local.xcconfig).
SIGNING=(CODE_SIGN_STYLE=Automatic "DEVELOPMENT_TEAM=$APEN_TEAM_ID" CODE_SIGN_IDENTITY="Apple Development"
         ENABLE_HARDENED_RUNTIME=YES)
step() { printf '\n\033[1m==> %s\033[0m\n' "$1"; }
