#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/release-common.sh"

# Test distribution guards without reading the Keychain or signing anything.
identity='Developer ID Application: Test Person (TESTTEAM00)'
signature_details="Authority=$identity
CodeDirectory v=20500 size=123 flags=0x10000(runtime) hashes=3+7 location=embedded"
codesign() {
  if [[ "$1" == --verify ]]; then return "${verification_result:-0}"; fi
  print -r -- "$signature_details"
}
security() { print -r -- "  1) TESTHASH \"$identity\""; }

assert_developer_id_identity_available "$identity"
assert_release_signed_app /fake/app "$identity"
if (assert_developer_id_identity_available 'Apple Development: Test') >/dev/null 2>&1; then
  fail "Development identity incorrectly accepted."
fi
signature_details='Signature=adhoc'
if (assert_release_signed_app /fake/app "$identity") >/dev/null 2>&1; then
  fail "Ad-hoc signature incorrectly accepted."
fi
signature_details="Authority=$identity"
if (assert_release_signed_app /fake/app "$identity") >/dev/null 2>&1; then
  fail "Non-hardened app incorrectly accepted."
fi
signature_details="Authority=${identity}Extra
CodeDirectory flags=0x10000(runtime)"
if (assert_release_signed_app /fake/app "$identity") >/dev/null 2>&1; then
  fail "Wrong authority incorrectly accepted."
fi
verification_result=1
if (assert_release_signed_app /fake/app "$identity") >/dev/null 2>&1; then
  fail "Invalid signature incorrectly accepted."
fi
print 'Release signing guard tests passed (no credentials used).'
