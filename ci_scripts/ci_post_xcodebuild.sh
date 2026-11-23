#!/bin/bash
# Xcode Cloud runs this after each xcodebuild action. After the archive of the Tester or App Store workflow, it
# uploads the archive's dSYMs to Sentry with a pinned sentry-cli. See docs/development.md, "Releases".
#
# The upload never fails the build: each problem is a warning, and the script always exits 0.
#
# sentry-cli reads its token from the Xcode Cloud secret SENTRY_AUTH_TOKEN. Xcode Cloud's logs are visible to the
# whole App Store Connect team, so this script never prints the token: no `set -x`, no token flag on the command
# line, and sentry-cli's log level stays at info.

set -uo pipefail

# The pinned sentry-cli: its version, and the SHA-256 of its universal macOS binary from GitHub's release.
sentry_cli_version="3.8.2"
sentry_cli_sha256="2d1b118fa46960ba5e8e0cca9a6e197366905776a0ddc5a89c7d05a3908b77db"

export SENTRY_ORG="codemonkeylabs"
export SENTRY_PROJECT="wishbone-ios"

warn() {
  echo "warning: ci_post_xcodebuild: $1 The dSYMs are not uploaded, and the build goes on."
  exit 0
}

case "${CI_WORKFLOW:-}" in
  Tester | "App Store") ;;
  *) exit 0 ;;
esac

[ "${CI_XCODEBUILD_ACTION:-}" = "archive" ] || exit 0
[ "${CI_XCODEBUILD_EXIT_CODE:-0}" = "0" ] || warn "the archive failed."
[ -n "${CI_ARCHIVE_PATH:-}" ] || warn "CI_ARCHIVE_PATH is missing."

dsyms="$CI_ARCHIVE_PATH/dSYMs"
[ -d "$dsyms" ] || warn "the archive has no dSYMs folder."
[ -n "${SENTRY_AUTH_TOKEN:-}" ] || warn "the Xcode Cloud secret SENTRY_AUTH_TOKEN is missing."

folder="$(mktemp -d)" || warn "could not make a folder for sentry-cli."
sentry_cli="$folder/sentry-cli"
url="https://github.com/getsentry/sentry-cli/releases/download/$sentry_cli_version/sentry-cli-Darwin-universal"

curl --fail --silent --show-error --location --retry 3 --output "$sentry_cli" "$url" ||
  warn "could not download sentry-cli $sentry_cli_version."
echo "$sentry_cli_sha256  $sentry_cli" | shasum --algorithm 256 --check --status ||
  warn "the download of sentry-cli $sentry_cli_version does not match its pinned SHA-256."
chmod +x "$sentry_cli"

unset SENTRY_LOG_LEVEL
echo "ci_post_xcodebuild: uploading the dSYMs to Sentry with sentry-cli $sentry_cli_version."
"$sentry_cli" --log-level info debug-files upload "$dsyms" ||
  warn "sentry-cli could not upload the dSYMs."
echo "ci_post_xcodebuild: uploaded the dSYMs to Sentry."
