#!/bin/sh
set -u

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/scripts/release-check-lib.sh"
mode=development
case "${1:-}" in
  "") ;;
  --strict) mode=strict ;;
  --production) mode=production ;;
  --help|-h) echo "Usage: scripts/release-check.sh [--strict|--production]"; exit 0 ;;
  *) echo "Unknown argument: $1" >&2; exit 64 ;;
esac
[ "$#" -le 1 ] || { echo "Too many arguments" >&2; exit 64; }

cd "$root"
log_root="$root/.build/release-check/logs"
mkdir -p "$log_root"
failures=0 warnings=0
summary_file="$root/.build/release-check/summary.tsv"
: > "$summary_file"

record() { printf '%s\t%s\t%s\n' "$1" "$2" "$3" >> "$summary_file"; }
pass() { record "$1" PASS "${2:-}"; }
warn() { warnings=$((warnings + 1)); record "$1" WARN "$2"; }
fail() { failures=$((failures + 1)); record "$1" FAIL "$2"; }
run_stage() {
  stage=$1 label=$2; shift 2
  log="$log_root/$stage.log"
  if "$@" >"$log" 2>&1; then pass "$label"; return 0; fi
  fail "$label" "see $log"
  echo "--- $label failure ($*) ---" >&2; tail -n 20 "$log" >&2
  return 1
}

metadata="$root/Config/Version.env"
if validate_version_metadata "$metadata"; then
  version=$(metadata_value "$metadata" MARKETING_VERSION)
  build=$(metadata_value "$metadata" BUILD_NUMBER)
  helper_protocol=$(metadata_value "$metadata" HELPER_PROTOCOL_VERSION)
  vdm_revision=$(metadata_value "$metadata" MACVDMTOOL_REVISION)
  pass "Version metadata"
else
  version=unknown build=unknown helper_protocol=unknown vdm_revision=unknown
  fail "Version metadata" "Config/Version.env is missing or malformed"
fi
git_commit=$(git rev-parse --short=12 HEAD 2>/dev/null || echo unavailable)

run_stage diff-check "Repository whitespace" git diff --check || true
working_tree=$(git status --porcelain 2>/dev/null || true)
if [ -z "$working_tree" ]; then pass "Repository"
elif [ "$(dirty_tree_outcome "$mode")" = FAIL ]; then fail "Repository" "dirty working tree"
else warn "Repository" "dirty working tree"
fi

generated=Sources/DFUCore/BuildMetadata.generated.swift
if [ "$version" != unknown ] && grep -Fq "public static let version = \"$version\"" "$generated" && grep -Fq "public static let build = \"$build\"" "$generated" && grep -Fq "public static let helperProtocolVersion = $helper_protocol" "$generated" && grep -Fq "public static let macVDMToolRevision = \"$vdm_revision\"" "$generated"; then
  pass "Generated metadata"
else fail "Generated metadata" "generated Swift metadata disagrees with Config/Version.env"
fi

run_stage debug-build "Debug build" swift build || true
if run_stage tests "Tests" swift test; then
  test_count=$(sed -n 's/.*Test run with \([0-9][0-9]*\) tests.*/\1/p' "$log_root/tests.log" | tail -1)
  [ -n "$test_count" ] || test_count=$(grep -c '^✔ Test .* passed' "$log_root/tests.log" || true)
  # Replace the generic test row with its dynamic count.
  sed -i '' '$d' "$summary_file"; pass "Tests" "$test_count"
else test_count=unknown; fi
run_stage release-build "Release build" swift build -c release || true

cli_ok=true
run_stage cli-doctor "CLI doctor" .build/release/dfuctl doctor || cli_ok=false
run_stage cli-status "CLI status" .build/release/dfuctl status || cli_ok=false
run_stage cli-latest "CLI IPSW latest" .build/release/dfuctl ipsw latest || cli_ok=false
run_stage cli-cache "CLI IPSW cache" .build/release/dfuctl ipsw cache || cli_ok=false
if [ "$cli_ok" = true ]; then pass "CLI smoke tests"; else fail "CLI smoke tests" "one or more read-only commands failed"; fi
if grep -q '^  Connected: No' "$log_root/cli-status.log"; then target_status="None connected"
else
  target_model=$(sed -n 's/^  Model: //p' "$log_root/cli-status.log" | head -1)
  target_state=$(sed -n 's/^  State: //p' "$log_root/cli-status.log" | head -1)
  target_status="${target_model:-Unknown} — ${target_state:-Unknown}"
fi

package_args=""
if [ "$mode" = production ]; then
  if [ -n "${DFUUTILITY_SIGNING_IDENTITY:-}" ]; then package_args=$DFUUTILITY_SIGNING_IDENTITY
  else fail "Production identity" "set DFUUTILITY_SIGNING_IDENTITY"; fi
fi
if [ "$mode" = production ]; then
  if [ -n "$package_args" ]; then run_stage package "App package" scripts/package-app.sh release --identity "$package_args" || true
  else fail "App package" "production packaging skipped without Developer ID identity"; fi
else
  run_stage package "App package" scripts/package-app.sh release || true
fi

app="$root/.build/app/DFUUtility.app"
components="Contents/MacOS/DFUUtility Contents/Library/LaunchServices/DFUPrivilegedHelper Contents/Library/LaunchDaemons/org.dfuutility.privileged-helper.plist Contents/Resources/AppIcon.icns Contents/Resources/DFUUtility-LICENSE.txt Contents/Resources/macvdmtool Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt"
missing=""
for component in $components; do [ -e "$app/$component" ] || missing="$missing $component"; done
if [ -z "$missing" ]; then pass "Bundle structure"; else fail "Bundle structure" "missing:$missing"; fi

if [ -d "$app" ]; then run_stage signature-verification "Nested signatures" scripts/verify-app.sh "$app" || true
else fail "Nested signatures" "application bundle missing"; fi

signature_text=$(codesign -dvvv "$app" 2>&1 || true)
signing_mode=$(classify_signature "$signature_text")
case "$signing_mode" in
  developer-id) pass "Signing mode" "Developer ID" ;;
  ad-hoc) if [ "$mode" = production ]; then fail "Signing mode" "ad-hoc signature in production mode"; else pass "Signing mode" "Development / ad-hoc"; fi ;;
  *) if [ "$mode" = production ]; then fail "Signing mode" "not Developer ID Application"; else warn "Signing mode" "unrecognized signing identity"; fi ;;
esac
if codesign -d --entitlements :- "$app" >"$log_root/app-entitlements.log" 2>&1 && codesign -d --entitlements :- "$app/Contents/Library/LaunchServices/DFUPrivilegedHelper" >"$log_root/helper-entitlements.log" 2>&1; then pass "Entitlements"; else fail "Entitlements" "could not inspect app/helper entitlements"; fi

packaged_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo missing)
packaged_build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist" 2>/dev/null || echo missing)
packaged_protocol=$(/usr/libexec/PlistBuddy -c 'Print :DFUUtilityHelperProtocolVersion' "$app/Contents/Info.plist" 2>/dev/null || echo missing)
packaged_icon=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIconFile' "$app/Contents/Info.plist" 2>/dev/null || echo missing)
if [ "$packaged_version" = "$version" ] && [ "$packaged_build" = "$build" ] && [ "$packaged_protocol" = "$helper_protocol" ] && [ "$packaged_icon" = AppIcon ]; then pass "Packaged metadata"; else fail "Packaged metadata" "Info.plist mismatch"; fi

if [ -s LICENSE ] && grep -Fq "Apache License" LICENSE && [ -s "$app/Contents/Resources/DFUUtility-LICENSE.txt" ]; then pass "Project license" "Apache License 2.0"; else fail "Project license" "project Apache-2.0 license missing from source or app bundle"; fi
if [ -s Vendor/macvdmtool/LICENSE ] && [ -s Vendor/macvdmtool/UPSTREAM_REVISION ] && [ -s Vendor/macvdmtool/README.upstream.md ] && grep -Fq "$vdm_revision" Vendor/macvdmtool/UPSTREAM_REVISION && [ -s "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt" ] && [ -s "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt" ]; then pass "Third-party licenses"; else fail "Third-party licenses" "macvdmtool attribution/license/revision incomplete"; fi

artifact="$root/.build/distribution/$(distribution_artifact_name "$version")"
if [ -f "$artifact" ] && unzip -Z1 "$artifact" >"$log_root/zip-contents.log" 2>&1 && grep -q '^DFUUtility.app/Contents/MacOS/DFUUtility$' "$log_root/zip-contents.log" && grep -q '^DFUUtility.app/Contents/Library/LaunchServices/DFUPrivilegedHelper$' "$log_root/zip-contents.log"; then
  pass "Distribution ZIP"
  zip_sha=$(shasum -a 256 "$artifact" | awk '{print $1}')
else fail "Distribution ZIP" "missing or malformed artifact"; zip_sha=unavailable; fi

identities=$(security find-identity -v -p codesigning 2>/dev/null || true)
developer_id=$(classify_identities "$identities")
if [ "$developer_id" = configured ]; then pass "Developer ID" "CONFIGURED"
elif [ "$mode" = production ]; then fail "Developer ID" "NOT CONFIGURED"
else warn "Developer ID" "NOT CONFIGURED"; fi

if [ "$signing_mode" = developer-id ] && xcrun stapler validate "$app" >"$log_root/stapler.log" 2>&1; then pass "Notarization" "STAPLED"
elif [ "$mode" = production ]; then fail "Notarization" "staple not verified"
else warn "Notarization" "NOT VERIFIED"; fi
acceptance="$root/Config/HardwareAcceptance.json"
acceptance_ok=true
if ! plutil -convert xml1 -o /dev/null "$acceptance" >/dev/null 2>&1; then acceptance_ok=false; fi
accepted_version=$(plutil -extract appVersion raw "$acceptance" 2>/dev/null || true)
accepted_name=$(plutil -extract hardware.displayName raw "$acceptance" 2>/dev/null || true)
accepted_identifier=$(plutil -extract hardware.identifier raw "$acceptance" 2>/dev/null || true)
for key in normalDetection guiEnterDFU sameECIDVerification guiRevive guiRestore liveProgress targetRestartVerification; do
  [ "$(plutil -extract "results.$key" raw "$acceptance" 2>/dev/null || true)" = PASS ] || acceptance_ok=false
done
if [ "$acceptance_ok" = true ] && [ "$accepted_version" = "$version" ] && [ -n "$accepted_name" ] && [ -n "$accepted_identifier" ]; then
  pass "Hardware acceptance" "$accepted_name ($accepted_identifier)"
else
  fail "Hardware acceptance" "missing, incomplete, or not recorded for version $version"
fi
warn "Hardware coverage" "broader Apple Silicon and Intel T2 coverage pending"

result=$(release_result "$failures" "$warnings" "$mode")
echo
echo "DFUUtility Release Check"
printf '%-23s %s (%s)\n' "Version" "$version" "$build"
printf '%-23s %s\n' "Git commit" "$git_commit"
printf '%-23s %s\n' "Helper protocol" "$helper_protocol"
printf '%-23s %s\n' "macvdmtool" "$vdm_revision"
while IFS="$(printf '\t')" read -r label status detail; do printf '%-23s %-4s%s\n' "$label" "$status" "${detail:+ — $detail}"; done < "$summary_file"
printf '%-23s %s\n' "Target" "$target_status"
printf '%-23s %s\n' "SHA-256" "$zip_sha"
echo "RESULT:"
case "$result" in
  FAIL) echo "FAIL — $failures failure(s), $warnings warning(s)"; exit 1 ;;
  PRODUCTION_RC_READY) echo "PRODUCTION RC READY" ;;
  DEVELOPMENT_RC_READY_WITH_WARNINGS) echo "DEVELOPMENT RC READY — $warnings warning(s)" ;;
  *) echo "DEVELOPMENT RC READY" ;;
esac
