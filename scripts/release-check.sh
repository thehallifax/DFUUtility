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

if [ -x scripts/update.sh ] && [ -x scripts/update-and-relaunch.sh ] && [ -x scripts/test-update.sh ] && sh -n scripts/update.sh && sh -n scripts/update-and-relaunch.sh && sh -n scripts/install-local.sh && sh -n scripts/test-update.sh && grep -Fq "Check for Updates" README.md && grep -Fq "scripts/update.sh" README.md && grep -Fq 'install -m 755 scripts/update-and-relaunch.sh' scripts/package-app.sh && ! grep -Fq '/Users/james' scripts/update-and-relaunch.sh; then
  pass "Updater" "scripts executable, syntax valid, launcher bundled, documented"
else
  fail "Updater" "update scripts must be executable, syntax valid, safely bundled, and documented"
fi

if [ -x scripts/install-release.sh ] && [ -x scripts/test-install-release.sh ] && sh -n scripts/install-release.sh && sh -n scripts/test-install-release.sh && grep -Fq "Quick Terminal install" README.md && ! grep -Fq 'update-source' scripts/install-release.sh; then
  pass "Release installer" "executable, syntax valid, distribution-only, documented"
else
  fail "Release installer" "release installer and harness must be executable, syntax valid, distribution-only, and documented"
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
components="Contents/MacOS/DFUUtility Contents/Library/LaunchServices/DFUPrivilegedHelper Contents/Library/LaunchDaemons/org.dfuutility.privileged-helper.plist Contents/Resources/DFUBinaryInstaller Contents/Resources/AppIcon.icns Contents/Resources/DFUUtility-LICENSE.txt Contents/Resources/macvdmtool Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM-NOTICE.md"
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
if [ -s Vendor/macvdmtool/LICENSE ] && [ -s Vendor/macvdmtool/UPSTREAM_REVISION ] && [ -s Vendor/macvdmtool/README.upstream.md ] && grep -Fq "$vdm_revision" Vendor/macvdmtool/UPSTREAM_REVISION && [ -s "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-Apache-2.0.txt" ] && [ -s "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM_REVISION.txt" ] && [ -s "$app/Contents/Resources/ThirdPartyLicenses/macvdmtool-UPSTREAM-NOTICE.md" ]; then pass "Third-party licenses"; else fail "Third-party licenses" "macvdmtool attribution/license/revision incomplete"; fi

screenshots_ok=true
for screenshot in multiple-devices normal-mac firmware-library device-capture-default diagnostics about update mac-dfu iphone-guided-dfu ipad-guided-dfu firmware-chooser download-progress restore-progress manage-downloads completed-restore; do
  [ -s "$root/docs/images/$screenshot.png" ] || screenshots_ok=false
done
if [ "$screenshots_ok" = true ]; then pass "Release screenshots" "16 deterministic assets"; else fail "Release screenshots" "one or more release screenshots are missing"; fi

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
mobile_ok=true
mobile_name=$(plutil -extract mobileHardware.displayName raw "$acceptance" 2>/dev/null || true)
mobile_product=$(plutil -extract mobileHardware.productType raw "$acceptance" 2>/dev/null || true)
for key in normalDetection recoveryDetection guidedDFU sameECIDVerification imageDiscovery guiImageDownload ipswValidation guiRestore liveProgress targetRestartVerification; do
  [ "$(plutil -extract "mobileHardware.results.$key" raw "$acceptance" 2>/dev/null || true)" = PASS ] || mobile_ok=false
done
if [ "$mobile_ok" = true ] && [ "$mobile_product" = iPhone7,2 ] && [ -n "$mobile_name" ]; then
  pass "iPhone acceptance" "$mobile_name ($mobile_product) — end-to-end"
else
  fail "iPhone acceptance" "iPhone7,2 acceptance missing or incomplete"
fi
ipad_product=$(plutil -extract iPadHardware.productType raw "$acceptance" 2>/dev/null || true)
ipad_normal=$(plutil -extract iPadHardware.results.normalDetection raw "$acceptance" 2>/dev/null || true)
ipad_recovery=$(plutil -extract iPadHardware.results.recoveryDetection raw "$acceptance" 2>/dev/null || true)
ipad_dfu=$(plutil -extract iPadHardware.results.guidedDFU raw "$acceptance" 2>/dev/null || true)
ipad_same_ecid=$(plutil -extract iPadHardware.results.sameECIDVerification raw "$acceptance" 2>/dev/null || true)
ipad_restore=true
for key in recoveryDetection guiRestore; do
  [ "$(plutil -extract "iPadHardware.results.$key" raw "$acceptance" 2>/dev/null || true)" = PASS ] || ipad_restore=false
done
ipad_unobserved_pending=true
for key in liveProgress targetRestartVerification; do
  [ "$(plutil -extract "iPadHardware.results.$key" raw "$acceptance" 2>/dev/null || true)" = PENDING ] || ipad_unobserved_pending=false
done
ipad_firmware=true
for key in imageDiscovery guiImageDownload ipswValidation; do
  [ "$(plutil -extract "iPadHardware.results.$key" raw "$acceptance" 2>/dev/null || true)" = PASS ] || ipad_firmware=false
done
if [ "$ipad_product" = iPad7,11 ] && [ "$ipad_normal" = PASS ] && [ "$ipad_dfu" = PASS ] && [ "$ipad_same_ecid" = PASS ] && [ "$ipad_firmware" = true ] && [ "$ipad_restore" = true ] && [ "$ipad_unobserved_pending" = true ]; then
  pass "iPad acceptance" "iPad7,11 — Recovery-mode Restore accepted; progress/restart verification pending"
else
  fail "iPad acceptance" "iPad7,11 status is missing or overclaims untested milestones"
fi
newer_mac_product=$(plutil -extract newerMacHardware.productType raw "$acceptance" 2>/dev/null || true)
newer_mac_ok=true
for key in discovery automaticEnterDFU dfuRediscovery guiRestore liveProgress targetRestartVerification; do
  [ "$(plutil -extract "newerMacHardware.results.$key" raw "$acceptance" 2>/dev/null || true)" = PASS ] || newer_mac_ok=false
done
newer_mac_port=$(plutil -extract newerMacHardware.portObservation raw "$acceptance" 2>/dev/null || true)
if [ "$newer_mac_product" = Mac17,6 ] && [ "$newer_mac_ok" = true ] && echo "$newer_mac_port" | grep -Fq "not a universal"; then
  pass "Newer Mac acceptance" "Mac17,6 — end-to-end with tested port-change caveat"
else
  fail "Newer Mac acceptance" "Mac17,6 acceptance or scoped port guidance is incomplete"
fi
multi_product=$(plutil -extract multiDeviceHardware.productType raw "$acceptance" 2>/dev/null || true)
multi_count=$(plutil -extract multiDeviceHardware.deviceCount raw "$acceptance" 2>/dev/null || true)
multi_restore=$(plutil -extract multiDeviceHardware.sequentialRestore raw "$acceptance" 2>/dev/null || true)
if [ "$multi_product" = iPad12,1 ] && [ "$multi_count" = 2 ] && [ "$multi_restore" = PASS ]; then
  pass "Multi-device acceptance" "two iPad12,1 Recovery targets — sequential Restore"
else
  fail "Multi-device acceptance" "two-device iPad12,1 sequential Restore acceptance missing"
fi
mobile_cache_product=$(plutil -extract mobileCachedFirmwareAssignment.productType raw "$acceptance" 2>/dev/null || true)
mobile_cache_ok=true
for key in exactCompatibleAssetAssigned validatedManagedCacheReused deviceRemainedUnselected recoveryRestoreReadiness explicitOperationSelectionRequired; do
  [ "$(plutil -extract "mobileCachedFirmwareAssignment.results.$key" raw "$acceptance" 2>/dev/null || true)" = PASS ] || mobile_cache_ok=false
done
if [ "$mobile_cache_product" = iPad12,1 ] && [ "$mobile_cache_ok" = true ]; then
  pass "Mobile cache assignment" "iPad12,1 — exact validated cache reused; operation selection remained explicit"
else
  fail "Mobile cache assignment" "physical cached-compatible mobile firmware assignment acceptance missing"
fi
warn "Hardware coverage" "Mac14,2, Mac17,6, and iPhone7,2 accepted end-to-end; iPad7,11 progress/restart verification pending; two-device iPad12,1 sequential Restore accepted; broader coverage pending"

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
