#!/bin/bash
# Xcode Cloud runs this after it clones the repo, before it builds. See docs/development.md, "Releases".
#
# For the Tester and App Store workflows, it writes Config/Local.xcconfig on the build machine: the real Sentry DSN
# (from the Xcode Cloud secret SENTRY_DSN), the Sentry environment, and Xcode Cloud's build number. Git ignores the
# file, and it exists only on the build machine.
#
# Xcode Cloud's logs are visible to the whole App Store Connect team, so this script never prints the DSN: no
# `set -x`, and no echo of the file or of the variable. It says only that it wrote the DSN, or that it is missing.

set -euo pipefail

repo="${CI_PRIMARY_REPOSITORY_PATH:-$(cd "$(dirname "$0")/.." && pwd)}"
local_config="$repo/Config/Local.xcconfig"

# The workflow's name gives the environment tag, which tells TestFlight builds from App Store builds.
case "${CI_WORKFLOW:-}" in
  Tester) environment=testflight ;;
  "App Store") environment=appstore ;;
  *)
    echo "ci_post_clone: '${CI_WORKFLOW:-}' is not a release workflow, so Config/Local.xcconfig is not written and the build sends no diagnostics."
    exit 0
    ;;
esac

if [ -z "${SENTRY_DSN:-}" ]; then
  echo "error: ci_post_clone: the Xcode Cloud secret SENTRY_DSN is missing. A $environment build must send diagnostics, so the build stops." >&2
  exit 1
fi

if [ -z "${CI_BUILD_NUMBER:-}" ]; then
  echo "error: ci_post_clone: CI_BUILD_NUMBER is missing, so the build has no build number." >&2
  exit 1
fi

# An xcconfig file treats `//` as the start of a comment, so the DSN's slashes are split: https:/$()/…
# The `$()` is xcconfig's, not the shell's. A variable keeps bash 3.2 from keeping the backslashes of the pattern.
# shellcheck disable=SC2016
split='/$()/'
dsn="${SENTRY_DSN//\/\//$split}"

umask 077
{
  printf '// Written by ci_scripts/ci_post_clone.sh on the Xcode Cloud build machine. Git ignores this file.\n'
  printf 'WISHBONE_SENTRY_DSN = %s\n' "$dsn"
  printf 'WISHBONE_SENTRY_ENVIRONMENT = %s\n' "$environment"
  printf 'CURRENT_PROJECT_VERSION = %s\n' "$CI_BUILD_NUMBER"
} >"$local_config"

echo "ci_post_clone: wrote the Sentry DSN, environment '$environment' and build number $CI_BUILD_NUMBER to Config/Local.xcconfig."
