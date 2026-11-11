#!/bin/bash
# Installs PartyPortal into ~/Applications:
#
#   curl -fsSL https://partyportal.inchi.dev/install.sh | bash
#
# It downloads the app from the latest GitHub release, checks it against the checksum published beside it,
# unpacks it and opens it. It also downloads cloudflared, which carries the public link, from Cloudflare's own
# releases into ~/Library/Application Support/PartyPortal, and after an update it clears
# PartyPortal's own two permission entries so that macOS asks for them again. Nothing needs sudo.
#
# For testing: PP_ARCHIVE=/path/to/PartyPortal-arm64.zip (with its .sha256 beside it) installs a local file,
# PP_INSTALL_DIR and PP_SUPPORT_DIR pick other folders, PP_NO_OPEN=1 does not open the app,
# PP_NO_CLOUDFLARED=1 leaves cloudflared alone, PP_CLOUDFLARED_URL takes it from elsewhere.
set -euo pipefail

RELEASES="https://github.com/inchidev/partyportal/releases/latest/download"

CLOUDFLARED="${PP_CLOUDFLARED_URL:-https://github.com/cloudflare/cloudflared/releases/latest/download}"

BUNDLE_ID="dev.inchi.partyportal"

die() { echo "PartyPortal: $*" >&2; exit 1; }

cdhash() { codesign -dv --verbose=4 "$1" 2>&1 | awk -F= '/^CDHash=/{print $2}'; }

# Without a Developer ID the app is signed ad hoc, and macOS ties its permissions to the exact build. After an
# update the old entries stay in System Settings, switched on, and do not count for the new build: the app says
# "missing" beside a switch that is on. Removing our own two entries makes macOS simply ask again.
# Not done when the same build is installed again, nor for a build with a real signature, whose permissions last.
reset_permissions() {
  local new="$1" old="$2" info
  info=$(codesign -dv "$new" 2>&1) || return 0
  case "$info" in *Signature=adhoc*) ;; *) return 0 ;; esac
  [ -d "$old" ] && [ "$(cdhash "$old")" = "$(cdhash "$new")" ] && return 0
  tccutil reset ScreenCapture "$BUNDLE_ID" > /dev/null 2>&1 || true
  tccutil reset Accessibility "$BUNDLE_ID" > /dev/null 2>&1 || true
}

# The public link needs cloudflared. It comes from Cloudflare, built for this Mac's processor, and is not
# part of our archive. Without it the app still works; only the public link is missing.
fetch_cloudflared() {
  local arch support
  case "$(uname -m)" in arm64) arch=arm64 ;; x86_64) arch=amd64 ;; *) return 1 ;; esac
  support="${PP_SUPPORT_DIR:-$HOME/Library/Application Support/PartyPortal}"
  echo "Downloading cloudflared (for the public link)…"
  curl -fL --progress-bar -o "$tmp/cloudflared.tgz" "$CLOUDFLARED/cloudflared-darwin-$arch.tgz" || return 1
  mkdir -p "$tmp/cf" && tar -xzf "$tmp/cloudflared.tgz" -C "$tmp/cf" || return 1
  [ -f "$tmp/cf/cloudflared" ] || return 1
  chmod 755 "$tmp/cf/cloudflared"
  "$tmp/cf/cloudflared" --version > /dev/null 2>&1 || return 1
  mkdir -p "$support" && mv -f "$tmp/cf/cloudflared" "$support/cloudflared"
}

# Everything in one function, so a download cut off half way runs nothing.
main() {
  [ "$(uname -s)" = "Darwin" ] || die "the host app is for macOS. A guest needs only a browser."
  local major; major=$(sw_vers -productVersion | cut -d. -f1)
  [ "$major" -ge 14 ] || die "macOS 14 or later is needed (this Mac has $(sw_vers -productVersion))."

  local name dest
  name="PartyPortal-$(uname -m).zip"
  dest="${PP_INSTALL_DIR:-$HOME/Applications}"
  tmp=$(mktemp -d)   # not local: the trap runs after this function has returned
  trap 'rm -rf "$tmp"' EXIT

  if [ -n "${PP_ARCHIVE:-}" ]; then
    cp "$PP_ARCHIVE" "$tmp/$name"
    cp "$PP_ARCHIVE.sha256" "$tmp/$name.sha256"
  else
    echo "Downloading PartyPortal…"
    curl -fL --progress-bar -o "$tmp/$name" "$RELEASES/$name" \
      || die "there is no download for this Mac ($(uname -m)) yet. Build it from source: https://github.com/inchidev/partyportal"
    curl -fsSL -o "$tmp/$name.sha256" "$RELEASES/$name.sha256" || die "the checksum could not be downloaded."
  fi

  local want got
  want=$(awk '{print $1; exit}' "$tmp/$name.sha256")
  got=$(shasum -a 256 "$tmp/$name" | awk '{print $1}')
  [ -n "$want" ] && [ "$want" = "$got" ] || die "the download does not match its checksum. Nothing was installed."

  ditto -x -k "$tmp/$name" "$tmp/out"
  [ -x "$tmp/out/PartyPortal.app/Contents/MacOS/partyportal" ] || die "the archive is not what was expected. Nothing was installed."
  codesign --verify --deep --strict "$tmp/out/PartyPortal.app" 2>/dev/null || die "the app's signature is broken. Nothing was installed."

  mkdir -p "$dest"
  reset_permissions "$tmp/out/PartyPortal.app" "$dest/PartyPortal.app"
  rm -rf "$dest/PartyPortal.app"
  mv "$tmp/out/PartyPortal.app" "$dest/PartyPortal.app"
  echo "Installed: $dest/PartyPortal.app"

  if [ -z "${PP_NO_CLOUDFLARED:-}" ] && ! fetch_cloudflared; then
    echo "cloudflared could not be installed: everything works except the public link. Run this command again later, or: brew install cloudflared" >&2
  fi

  if pgrep -x partyportal > /dev/null; then
    echo "PartyPortal is running. Quit it from its menu bar mark and open it again to use this version."
  elif [ -z "${PP_NO_OPEN:-}" ]; then
    open "$dest/PartyPortal.app"
    echo "Opening it. macOS will ask for two permissions: Screen Recording and Accessibility."
  fi
  echo "To update, run the same command again. After an update macOS asks for the two permissions again."
}

main "$@"
