#!/bin/sh

metadata_value() {
  [ "$#" -eq 2 ] && [ -f "$1" ] || return 1
  count=$(sed -n "s/^$2=//p" "$1" | wc -l | tr -d ' ')
  [ "$count" = 1 ] || return 1
  sed -n "s/^$2=//p" "$1"
}

validate_version_metadata() {
  file=$1
  version=$(metadata_value "$file" MARKETING_VERSION) || return 1
  build=$(metadata_value "$file" BUILD_NUMBER) || return 1
  protocol=$(metadata_value "$file" HELPER_PROTOCOL_VERSION) || return 1
  revision=$(metadata_value "$file" MACVDMTOOL_REVISION) || return 1
  case "$version" in *[!0-9.]*|''|.*|*.) return 1 ;; esac
  case "$build" in *[!0-9]*|'') return 1 ;; esac
  case "$protocol" in *[!0-9]*|'') return 1 ;; esac
  case "$revision" in *[!0-9a-fA-F]*|'') return 1 ;; esac
  [ "${#revision}" -ge 7 ]
}

distribution_artifact_name() { printf 'DFUUtility-%s.zip\n' "$1"; }

classify_identities() {
  if printf '%s\n' "$1" | grep -q '"Developer ID Application:'; then echo configured; else echo not-configured; fi
}

classify_signature() {
  text=$1
  if printf '%s\n' "$text" | grep -q '^Authority=Developer ID Application:'; then echo developer-id
  elif printf '%s\n' "$text" | grep -q '^Signature=adhoc' || printf '%s\n' "$text" | grep -q '^TeamIdentifier=not set'; then echo ad-hoc
  else echo other
  fi
}

release_result() {
  failures=$1 warnings=$2 mode=$3
  if [ "$failures" -gt 0 ]; then echo FAIL
  elif [ "$mode" = production ]; then echo PRODUCTION_RC_READY
  elif [ "$warnings" -gt 0 ]; then echo DEVELOPMENT_RC_READY_WITH_WARNINGS
  else echo DEVELOPMENT_RC_READY
  fi
}

dirty_tree_outcome() { if [ "$1" = strict ] || [ "$1" = production ]; then echo FAIL; else echo WARN; fi; }
