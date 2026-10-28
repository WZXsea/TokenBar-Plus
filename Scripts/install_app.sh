#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
SOURCE="$ROOT/TokenBar.app"
DESTINATION="/Applications/TokenBar.app"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

# Keep rollback archives out of application discovery and preserve the installed
# bundle directory so login items continue to reference the same application.
codesign --verify --deep --strict "$SOURCE"
[[ ! -L "$SOURCE" && ! -L "$DESTINATION" ]]
[[ "$(plutil -extract CFBundleIdentifier raw -o - "$SOURCE/Contents/Info.plist")" == "com.wuruoye.TokenBar" ]]
mkdir -p "$ROOT/.build/install"
if [[ -d "$DESTINATION" ]]; then
  [[ "$(plutil -extract CFBundleIdentifier raw -o - "$DESTINATION/Contents/Info.plist")" == "com.wuruoye.TokenBar" ]]
  ditto -c -k --sequesterRsrc --keepParent "$DESTINATION" "$ROOT/.build/install/TokenBar-previous.zip"
fi

STAGING="$(mktemp -d "$ROOT/.build/install/.staging.XXXXXX")"
cleanup() {
  local status=$?
  if [[ $status -ne 0 && -d "$STAGING/previousContents" ]]; then
    rm -rf -- "$DESTINATION/Contents"
    mv "$STAGING/previousContents" "$DESTINATION/Contents"
    echo "Restored the previous installed application." >&2
  fi
  rm -rf -- "$STAGING"
  return "$status"
}
trap cleanup EXIT
ditto "$SOURCE/Contents" "$STAGING/Contents"

PIDS="$(pgrep -f '^/Applications/TokenBar.app/Contents/MacOS/TokenBar$' || true)"
for pid in $PIDS; do
  kill -TERM "$pid"
done
for ((attempt = 0; attempt < 50; attempt++)); do
  if ! pgrep -f '^/Applications/TokenBar.app/Contents/MacOS/TokenBar$' >/dev/null; then
    break
  fi
  sleep 0.1
done
if pgrep -f '^/Applications/TokenBar.app/Contents/MacOS/TokenBar$' >/dev/null; then
  echo "TokenBar is still shutting down; installation remains staged at $SOURCE" >&2
  exit 1
fi

mkdir -p "$DESTINATION"
if [[ -d "$DESTINATION/Contents" ]]; then
  mv "$DESTINATION/Contents" "$STAGING/previousContents"
fi
mv "$STAGING/Contents" "$DESTINATION/Contents"
codesign --verify --deep --strict "$DESTINATION"
cmp "$SOURCE/Contents/MacOS/TokenBar" "$DESTINATION/Contents/MacOS/TokenBar"
cmp "$SOURCE/Contents/Helpers/tokenbar-helper" "$DESTINATION/Contents/Helpers/tokenbar-helper"
ditto -c -k --sequesterRsrc --keepParent "$SOURCE" "$ROOT/.build/install/TokenBar-current.zip"
"$LSREGISTER" -u "$SOURCE"
rm -rf -- "$SOURCE"
"$LSREGISTER" -f "$DESTINATION"
echo "Installed $DESTINATION; build and rollback copies are ZIP archives in .build/install."
