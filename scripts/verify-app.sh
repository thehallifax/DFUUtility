#!/bin/sh
set -eu
usage() { echo "Usage: scripts/verify-app.sh /path/to/DFUUtility.app" >&2; exit 64; }
[ "$#" -eq 1 ] || usage
app=$1
[ -d "$app" ] || { echo "App not found: $app" >&2; exit 1; }
helper="$app/Contents/Library/LaunchServices/DFUPrivilegedHelper"
vdm="$app/Contents/Resources/macvdmtool"
[ -x "$helper" ] && [ -x "$vdm" ] || { echo "Required nested executable is missing" >&2; exit 1; }

signature_field() { codesign -dvv "$1" 2>&1 | sed -n "s/^$2=//p" | head -1; }
for code in "$vdm" "$helper" "$app"; do codesign --verify --strict --verbose=2 "$code"; done
codesign --verify --deep --strict --verbose=2 "$app"
app_team=$(signature_field "$app" TeamIdentifier)
helper_team=$(signature_field "$helper" TeamIdentifier)
vdm_team=$(signature_field "$vdm" TeamIdentifier)
[ "$app_team" = "$helper_team" ] && [ "$app_team" = "$vdm_team" ] || { echo "Team ID mismatch: app=$app_team helper=$helper_team macvdmtool=$vdm_team" >&2; exit 1; }

echo "Main app: valid ($(signature_field "$app" Identifier))"
echo "Privileged helper: valid ($(signature_field "$helper" Identifier))"
echo "macvdmtool: valid ($(signature_field "$vdm" Identifier))"
echo "Team ID: ${app_team:-Ad hoc}"
echo "App entitlements:"; codesign -d --entitlements :- "$app" 2>/dev/null || true
echo "Helper entitlements:"; codesign -d --entitlements :- "$helper" 2>/dev/null || true

if [ -n "$app_team" ] && [ "$app_team" != "not set" ]; then
  for code in "$vdm" "$helper" "$app"; do codesign -dvv "$code" 2>&1 | grep -q 'flags=.*runtime' || { echo "Hardened runtime missing: $code" >&2; exit 1; }; done
  if codesign -d --entitlements :- "$app" 2>/dev/null | grep -q 'com.apple.security.get-task-allow'; then echo "Production app contains get-task-allow" >&2; exit 1; fi
  if xcrun stapler validate "$app" >/dev/null 2>&1; then
    spctl --assess --type execute --verbose=2 "$app"
  else
    echo "Gatekeeper notarization assessment: deferred until notarization/stapling"
  fi
else
  echo "Hardened runtime/Gatekeeper production checks: skipped for explicit ad-hoc development build"
fi
echo "Verification passed"
