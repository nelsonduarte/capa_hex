#!/usr/bin/env bash
#
# THE PIN, AUDITED BY CONTENT.
#
# release.yml pins the shared release guards by commit SHA, and the
# question that pin is supposed to answer is "which bytes will run".
# Until .github/guard-pins.sha256 existed, that question was answered by
# a value the platform handed the guards rather than by anything
# observable about the files: the guards read a revision from the job
# context and then checked that `actions/checkout` had fetched that same
# revision, which is one number compared with itself. Two revisions that
# are byte-identical are indistinguishable by such a check, and two that
# are NOT identical are exactly the case that must be caught.
#
# So .github/guard-pins.sha256 records the digest of every guard file at
# the revision this repository audited, and this test re-fetches each one
# and compares. A pin bumped without re-auditing goes red on the revision
# line; a pin whose bytes are not the audited bytes goes red on a digest.
# Neither outcome depends on anything the guards say about themselves.
#
# Run it directly:
#
#   bash tests/test_guard_pins.sh
#
# `capa test` runs the .capa files in tests/ and ignores this one.
#
# It reports SKIP rather than failing when `gh` is missing or
# unauthenticated, matching tests/test_release_wiring.sh: an offline
# machine cannot fetch the canonical bytes, and a test that guesses at
# them is the failure mode this file is about. The pin itself is still
# checked offline, because a malformed pin means there is no canonical
# revision to compare against and that is knowable without the network.
#
# WHY THIS IS NOT capa_authgate's tests/test_guard_drift.sh, which is
# where it came from. That file does this AND holds a local copy of
# tools/check_tag_version.sh byte-identical to the pinned one. The local
# copy exists there so the guard can be run offline on a laptop, and it
# is a real cost: a second copy of a security control that a test has to
# work to keep honest, in a repository that would otherwise have none.
# This package keeps no such copy, so the half of that file which policed
# it would assert nothing here, and a check that asserts nothing is worse
# than an absent one because it lengthens a passing log. What is left is
# the part that applies to every adopter, and this file is intended to be
# byte-identical across all of them: it has no repo-specific
# configuration at all.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORKFLOW="${REPO_ROOT}/.github/workflows/release.yml"
PINS="${REPO_ROOT}/.github/guard-pins.sha256"

GUARD_REPO="nelsonduarte/capa-language"

PASS=0
FAIL=0
SKIP=0

ok()   { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
no()   { FAIL=$((FAIL + 1)); printf 'FAIL %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)); printf 'skip %s\n' "$1"; }

finish() {
  printf '\n%s passed, %s failed, %s skipped\n' "${PASS}" "${FAIL}" "${SKIP}"
  [ "${FAIL}" = "0" ]
}

if [ ! -f "${WORKFLOW}" ]; then
  echo "FAIL: ${WORKFLOW} not found" >&2
  exit 1
fi

# The revision to compare against is not a constant in this file: it is
# whatever release.yml pins, so bumping the pin retargets the comparison
# and a stale audit record goes red at the bump rather than silently
# later.
PIN="$(sed -n 's|^[[:space:]]*uses:[[:space:]]*'"${GUARD_REPO}"'/\.github/workflows/release-guards\.yml@||p' "${WORKFLOW}")"
PIN="${PIN%%[[:space:]]*}"

if printf '%s' "${PIN}" | grep -qE '^[0-9a-f]{40}$'; then
  ok "release.yml pins a full 40-character guard revision (${PIN})"
else
  no "release.yml does not pin a full 40-character guard revision (got '${PIN}')"
  finish
  exit 1
fi

if [ ! -f "${PINS}" ]; then
  no "the audited guard digests are recorded (.github/guard-pins.sha256)"
  finish
  exit 1
fi
ok "the audited guard digests are recorded (.github/guard-pins.sha256)"

AUDITED_REV="$(awk '$1 == "revision" { print $2; exit }' "${PINS}")"

if [ -z "${AUDITED_REV}" ]; then
  no "guard-pins.sha256 names no revision; it cannot describe anything"
  finish
  exit 1
fi

if [ "${AUDITED_REV}" != "${PIN}" ]; then
  no "the audited revision is not the pinned one"
  echo "     release.yml pins        ${PIN}"
  echo "     guard-pins.sha256 names ${AUDITED_REV}"
  echo "     re-read the diff between them, then re-record the digests"
  finish
  exit 1
fi
ok "the audited revision is the one release.yml pins"

# One digest line per guard file: "<sha256>  <path>".
ENTRIES="$(grep -E '^[0-9a-f]{64}[[:space:]]+[^[:space:]]+' "${PINS}" || true)"

if [ -z "${ENTRIES}" ]; then
  no "guard-pins.sha256 records no digests; it would pass having checked nothing"
  finish
  exit 1
fi

# The record must cover every file the guards actually EXECUTE. Recording
# four of five files still produces a fully green log while one script
# runs unaudited, and the file most likely to be forgotten is the newest
# one, which is also the one nobody has read before.
for required in \
  .github/workflows/release-guards.yml \
  tools/check_tag_version.sh \
  tools/clean_room_build.sh \
  tools/capa_floor.sh
do
  if printf '%s\n' "${ENTRIES}" | grep -qF "  ${required}"; then
    ok "the audit record covers ${required}"
  else
    no "the audit record omits ${required}, which the guards execute"
  fi
done

# verify_guard_digests.sh runs only if this repository passes
# guard-digests, so it is required exactly when that input is present.
if grep -qE '^[[:space:]]*guard-digests:[[:space:]]*\|' "${WORKFLOW}"; then
  if printf '%s\n' "${ENTRIES}" | grep -qF "  tools/verify_guard_digests.sh"; then
    ok "the audit record covers tools/verify_guard_digests.sh, which guard-digests causes to run"
  else
    no "release.yml passes guard-digests but the audit record omits tools/verify_guard_digests.sh"
  fi
fi

if ! command -v gh >/dev/null 2>&1; then
  skip "every guard file matches its audited digest (gh not installed)"
  finish
  exit $?
elif ! gh auth status >/dev/null 2>&1; then
  skip "every guard file matches its audited digest (gh not authenticated)"
  finish
  exit $?
fi

while read -r want path; do
  [ -z "${path}" ] && continue
  got="$(gh api "repos/${GUARD_REPO}/contents/${path}?ref=${PIN}" \
           --jq .content 2>/dev/null | base64 -d | sha256sum | cut -d' ' -f1)"
  if [ -z "${got}" ]; then
    no "${path} could not be fetched at ${PIN}; the pin may not carry it"
  elif [ "${got}" = "${want}" ]; then
    ok "${path} matches its audited digest"
  else
    no "${path} at ${PIN} is NOT the audited file"
    echo "     audited ${want}"
    echo "     fetched ${got}"
  fi
done <<< "${ENTRIES}"

finish
