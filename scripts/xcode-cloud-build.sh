#!/bin/bash
# Start a TestFlight or App Store build in Xcode Cloud, and give it to the testers. See docs/development.md,
# "Releases".
#
#   scripts/xcode-cloud-build.sh [options] "What to Test"
#
# First it finds the commit at the head of the branch on GitHub, and checks it with the Gate job of the CI workflow
# (the full `just gate` on a hosted runner). An App Store build waits for a green Gate run on that exact commit, and
# starts no build when the Gate fails. A Tester build starts a Gate run and doesn't wait for it.
#
# Then it starts the workflow on the branch, waits for the build run and for App Store Connect to process the build,
# sets the build's What to Test notes, and then adds the build to the TestFlight group, which tells the testers.
#
# The notes are an argument, never a file in the repo. The App Store Connect key is the one that `asc` has on this
# machine: its default profile, or the profile in ASC_PROFILE.

set -euo pipefail

app_id="6835721833"
repo="jsclayton/wishbone-ios"
default_group="bce08d06-abaf-43e4-b5db-4ada04ddf3cd" # The internal TestFlight group 'John'
locale="en-US"

usage() {
  cat <<'EOF'
Usage: scripts/xcode-cloud-build.sh [options] "What to Test"

Start the Tester workflow in Xcode Cloud, wait for the build, set its What to Test notes, and add it to the
TestFlight group.

Before the build, it starts the CI workflow's Gate job on the commit at the head of the branch. A Tester build
doesn't wait for it. An App Store build waits for a green Gate run on that commit (or uses one that passed
before), and starts no build if the Gate fails.

Options:
  --app-store      Start the App Store workflow instead of Tester. Its build can go to the App Store
  --branch NAME    The branch or tag to build. Default: main
  --group ID       The TestFlight group to add the build to. Default: the internal group 'John'
  --build-only     Stop when the build is processed: set no notes and add it to no group. Takes no notes.
                   The Gate runs as for the workflow that it builds
  -h, --help       Show this help
EOF
}

workflow="Tester"
branch="main"
group="$default_group"
build_only=false
notes=""
have_notes=false

while [ $# -gt 0 ]; do
  case "$1" in
    --app-store) workflow="App Store" ;;
    --branch)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      branch="$2"
      shift
      ;;
    --group)
      [ $# -ge 2 ] || { usage >&2; exit 2; }
      group="$2"
      shift
      ;;
    --build-only) build_only=true ;;
    -h | --help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
  shift
done

if [ $# -gt 1 ]; then
  echo "Give the notes as one argument, in quotes." >&2
  exit 2
elif [ $# -eq 1 ]; then
  notes="$1"
  have_notes=true
fi

if $build_only; then
  if $have_notes; then
    echo "--build-only sets no notes, so it takes none." >&2
    exit 2
  fi
elif [ -z "${notes//[[:space:]]/}" ]; then
  echo "Give the What to Test notes as the argument: what the testers should look at in this build." >&2
  usage >&2
  exit 2
fi

for tool in asc gh jq; do
  command -v "$tool" >/dev/null || { echo "$tool is not installed." >&2; exit 1; }
done

say() { printf '%s  %s\n' "$(date +%H:%M:%S)" "$*"; }

# asc reads a value that starts with @ as a file or a variable (@file:PATH, @env:NAME). A literal @ is @@.
asc_literal() {
  case "$1" in
    @*) printf '@%s' "$1" ;;
    *) printf '%s' "$1" ;;
  esac
}

# The Gate job of the CI workflow (.github/workflows/ci.yml) runs only when it is started by hand
# (workflow_dispatch). A run's name is "Gate on <sha>", so a run is matched to its commit by its name.

# The full SHA of the commit at the head of a branch or tag on GitHub.
resolve_commit() {
  gh api "repos/$repo/commits/$1" --jq .sha
}

# The Gate run for a commit that counts: the newest one that passed, or else the newest one that hasn't ended. It
# prints "<run ID> <status> <URL>", or nothing when there is neither. A run that failed doesn't count.
find_gate_run() {
  gh run list --repo "$repo" --workflow ci.yml --event workflow_dispatch --limit 100 \
    --json databaseId,displayTitle,status,conclusion,url |
    jq -r --arg title "Gate on $1" '
      [.[] | select(.displayTitle == $title)] as $runs
      | ([$runs[] | select(.status == "completed" and .conclusion == "success")]
        + [$runs[] | select(.status != "completed")])
      | first // empty
      | "\(.databaseId) \(.status) \(.url)"'
}

# Start a Gate run for a commit, from the workflow on the branch. It prints "<run ID> <URL>".
dispatch_gate() {
  local ref="$1" sha="$2" url="" found=""
  url="$(gh workflow run ci.yml --repo "$repo" --ref "$ref" -f sha="$sha" 2>&1 | grep -Eo 'https://[^ ]+/actions/runs/[0-9]+' | head -n 1 || true)"
  if [ -z "$url" ]; then
    # An older gh prints no URL. The run shows in the list after a few seconds.
    for _ in $(seq 1 12); do
      sleep 10
      found="$(find_gate_run "$sha")"
      [ -n "$found" ] && break
    done
    [ -n "$found" ] || { echo "Started the Gate on $sha, but can't find its run." >&2; return 1; }
    url="${found##* }"
  fi
  printf '%s %s\n' "${url##*/}" "$url"
}

# Wait for a Gate run to end, for at most three hours. It succeeds only when the run passed.
wait_gate() {
  local id="$1" view="" status="" conclusion=""
  for _ in $(seq 1 180); do
    view="$(gh run view "$id" --repo "$repo" --json status,conclusion)" || view=""
    status="$(jq -r '.status // empty' <<<"$view" 2>/dev/null || true)"
    if [ "$status" = "completed" ]; then
      conclusion="$(jq -r '.conclusion // empty' <<<"$view")"
      [ "$conclusion" = "success" ]
      return
    fi
    sleep 60
  done
  echo "The Gate run $id hasn't ended after three hours." >&2
  return 1
}

# 1. Check the commit with the Gate.
sha="$(resolve_commit "$branch")" || { echo "Can't find '$branch' on GitHub ($repo)." >&2; exit 1; }
say "'$branch' is at $sha on GitHub."
if [ "$workflow" = "App Store" ]; then
  gate_run="$(find_gate_run "$sha")"
  if [ -n "$gate_run" ] && [ "$(cut -d ' ' -f 2 <<<"$gate_run")" = "completed" ]; then
    say "The Gate passed on $sha: ${gate_run##* }"
  else
    if [ -n "$gate_run" ]; then
      gate_id="${gate_run%% *}"
      gate_url="${gate_run##* }"
      say "A Gate run on $sha is under way: $gate_url"
    else
      gate_run="$(dispatch_gate "$branch" "$sha")"
      gate_id="${gate_run%% *}"
      gate_url="${gate_run##* }"
      say "Started the Gate on $sha: $gate_url"
    fi
    say "Waiting for the Gate to pass before the App Store build (this takes up to an hour)."
    if ! wait_gate "$gate_id"; then
      echo "The Gate didn't pass on $sha, so no App Store build was started. See: $gate_url" >&2
      exit 1
    fi
    say "The Gate passed on $sha."
  fi
else
  gate_run="$(dispatch_gate "$branch" "$sha")"
  say "Started the Gate on $sha. The build doesn't wait for it: ${gate_run##* }"
fi

# 2. Start the workflow.
say "Starting the $workflow workflow on '$branch'."
run_json="$(asc xcode-cloud run --app "$app_id" --workflow "$workflow" --branch "$(asc_literal "$branch")" --output json)"
run_id="$(jq -r '.data.id // .buildRunId // .runId // .id // empty' <<<"$run_json")"
if [ -z "$run_id" ]; then
  echo "asc started the run, but its answer has no run ID:" >&2
  echo "$run_json" >&2
  exit 1
fi
say "Build run $run_id started. Waiting for it to finish (this takes a while)."

# 3. Wait for the build run, for at most three hours.
progress=""
for _ in $(seq 1 180); do
  view="$(asc xcode-cloud build-runs view --id "$run_id" --output json)" || view=""
  new_progress="$(jq -r '.data.attributes.executionProgress // empty' <<<"$view" 2>/dev/null || true)"
  if [ -n "$new_progress" ] && [ "$new_progress" != "$progress" ]; then
    progress="$new_progress"
    say "Build run $run_id: $progress"
  fi
  [ "$progress" = "COMPLETE" ] && break
  sleep 60
done
if [ "$progress" != "COMPLETE" ]; then
  echo "Build run $run_id is not complete after three hours. See it with: asc xcode-cloud status --run-id $run_id" >&2
  exit 1
fi
status="$(jq -r '.data.attributes.completionStatus // empty' <<<"$view")"
number="$(jq -r '.data.attributes.number // empty' <<<"$view")"
if [ "$status" != "SUCCEEDED" ]; then
  echo "Build run $run_id (number $number) ended $status. See it with: asc xcode-cloud doctor --run-id $run_id" >&2
  exit 1
fi
say "Build run $run_id (number $number) succeeded."

# 4. Find the build that the run uploaded. App Store Connect can take a few minutes to list it.
build_id=""
for _ in $(seq 1 30); do
  builds="$(asc xcode-cloud build-runs builds --run-id "$run_id" --output json)" || builds=""
  build_id="$(jq -r '.data[0].id // empty' <<<"$builds" 2>/dev/null || true)"
  [ -n "$build_id" ] && break
  sleep 30
done
if [ -z "$build_id" ]; then
  echo "Build run $run_id has no build in App Store Connect after 15 minutes." >&2
  exit 1
fi
build_number="$(jq -r '.data[0].attributes.version // empty' <<<"$builds")"
say "Build $build_number ($build_id). Waiting for App Store Connect to process it."

# 5. Wait for processing.
asc builds wait --build-id "$build_id" --fail-on-invalid --timeout 90m --poll-interval 30s >/dev/null
say "Build $build_number is processed."

if $build_only; then
  say "Done: build $build_number ($build_id), with no notes and in no group (--build-only)."
  exit 0
fi

# 6. Set What to Test. Add the group only after this, because adding the group is what tells the testers.
whats_new="$(asc_literal "$notes")"
existing="$(asc builds test-notes list --build-id "$build_id" --output json |
  jq -r --arg locale "$locale" '.data[]? | select(.attributes.locale == $locale) | .id' | head -n 1)"
if [ -n "$existing" ]; then
  asc builds test-notes update --localization-id "$existing" --whats-new "$whats_new" --output json >/dev/null
else
  asc builds test-notes create --build-id "$build_id" --locale "$locale" --whats-new "$whats_new" --output json >/dev/null
fi
say "Set the What to Test notes of build $build_number."

# 7. Add the build to the group.
asc builds add-groups --build-id "$build_id" --group "$group" --output json >/dev/null
say "Done: build $build_number is in the TestFlight group, with its notes."
