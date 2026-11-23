# Wishbone for iPhone and iPad - development workflow

set shell := ["bash", "-euo", "pipefail", "-c"]

derived_data := "build/DerivedData"
catalog := "WishboneKit/Sources/WishboneUI/Resources/Localizable.xcstrings"
swift_dirs := "Wishbone ShareExtension WidgetExtension HostedTests JourneyTests WishboneKit/Package.swift WishboneKit/Sources WishboneKit/Tests"

# List recipes
default:
    @just --list

# ============================================================================
# The gate
# ============================================================================

# Run every check that a pull request must pass. Its last line is the result
[no-exit-message]
gate:
    node scripts/gate/main.mjs

# ============================================================================
# Build
# ============================================================================

# The build is also the simulator tier's build: the gate's simulator step runs the tests that it built, and
# `just simulator` by itself builds with the same arguments (`buildArguments` in scripts/gate/simulator.mjs). A
# gate test holds the two to one build.

# Build the app, both extensions and the test bundles for the simulator, then add new strings to the String Catalog, make the Acknowledgements, and register the catalog's merge driver
build:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p build
    xcodebuild build-for-testing \
        -project Wishbone.xcodeproj \
        -scheme Wishbone \
        -configuration Debug \
        -destination 'generic/platform=iOS Simulator' \
        -derivedDataPath {{derived_data}} \
        ARCHS=arm64 \
        > build/xcodebuild.log 2>&1 || { grep -E '(error|warning): ' build/xcodebuild.log || tail -n 40 build/xcodebuild.log; exit 1; }
    # The build has zero warnings. A warning from the compiler is an error, in the targets (the project's
    # SWIFT_TREAT_WARNINGS_AS_ERRORS) and in the package (Package.swift), so it fails every build until it is
    # fixed. The check below is for what the compiler doesn't own: the linker,
    # the asset catalogs, and the project. xcodebuild prints those only when it runs the step again.
    # Xcode's App Intents step logs "warning: Metadata extraction skipped" for a target with no App Intents. That
    # line is the step's own log, not a warning about the code.
    warnings="$(grep -E 'warning: ' build/xcodebuild.log | grep -v 'appintentsmetadataprocessor.*Metadata extraction skipped' || true)"
    if [ -n "$warnings" ]; then
        echo "$warnings"
        echo "✗ The build has warnings (log: build/xcodebuild.log)" >&2
        exit 1
    fi
    just sync-strings
    just acknowledgements
    node scripts/xcstrings-merge.mjs --register
    echo "✓ Built Wishbone, ShareExtension, WidgetExtension and the test bundles for the simulator (log: build/xcodebuild.log)"

# Xcode adds new strings to the catalog when it builds. A build from the command line only writes
# what the compiler found, so this recipe adds it to the catalog.

# Add the strings that the last build found to the String Catalog
[private]
sync-strings:
    #!/usr/bin/env bash
    set -euo pipefail
    sources="WishboneKit/Sources/WishboneUI"
    intermediates="{{derived_data}}/Build/Intermediates.noindex/WishboneKit.build/Debug-iphonesimulator"
    args=()
    # One .stringsdata file for each Swift file. The build folder can hold one for a file that is gone, so take
    # only those of the files that exist.
    while IFS= read -r source; do
        data="$(find "$intermediates" -path '*/WishboneUI*/Objects-normal/arm64/*' -name "$(basename "$source" .swift).stringsdata" | head -n 1)"
        if [ -z "$data" ]; then
            echo "The build has no strings data for $source. Run 'just build' first." >&2
            exit 1
        fi
        args+=(--stringsdata "$data")
    done < <(find "$sources" -name '*.swift' | sort)
    xcrun xcstringstool sync {{catalog}} "${args[@]}"

# The Acknowledgements screen shows the license of each package that the app ships. The texts come from the
# packages that the build fetched, at their pinned commits, and go into a file in git.

# Make the license texts of the Acknowledgements screen from the pinned packages
[private]
acknowledgements:
    node scripts/acknowledgements.mjs

# ============================================================================
# Test
# ============================================================================

# Fetch and build the pinned Wishbone server that the tests run against, or reuse the built one
server:
    node scripts/server/build.mjs

# Take the copy of the pinned server's OpenAPI document again. Run it when the pin moves
server-openapi:
    node scripts/server/openapi.mjs

# Run the package tests on macOS, against the pinned server, at most 8 at a time. It passes its arguments to `swift test`
[positional-arguments]
test *args: server
    swift test --package-path WishboneKit --experimental-maximum-parallelization-width 8 "$@"

# Run the hosted tests and the journeys on the gate's own simulator, in the gate slot. The results go to the folder. `--no-build`, before or after the folder, runs what `just build` built
[positional-arguments]
simulator results="build/simulator" *flags: server
    node scripts/gate/simulator.mjs "$@"

# ============================================================================
# Lint and format
# ============================================================================

# Run every linter, the docs check, and the tests of the gate's scripts. It reports, and changes nothing
lint: lint-swift lint-ci lint-docs test-gate

# Lint the Swift files with swift-format
lint-swift:
    xcrun swift-format lint --strict --recursive --parallel {{swift_dirs}}

# actionlint also runs shellcheck on each `run:` script in a workflow, so shellcheck must be installed.

# Lint the GitHub workflows with actionlint, and the shell scripts with shellcheck
lint-ci:
    actionlint
    git ls-files -z --cached --others --exclude-standard -- '*.sh' | xargs -0 shellcheck

# Check the links in the Markdown files, and the ADR and screen indexes
lint-docs:
    node scripts/check-docs.mjs

# Run the tests of the gate's own scripts, and of the scripts that the recipes run
test-gate:
    node --test 'scripts/*.test.mjs' 'scripts/gate/*.test.mjs' 'scripts/server/*.test.mjs'

# Format the Swift files in place with swift-format
fmt:
    xcrun swift-format format --in-place --recursive --parallel {{swift_dirs}}

# ============================================================================
# Releases
# ============================================================================

# Start a TestFlight build in Xcode Cloud, then set its What to Test notes and add it to the group. `--app-store` starts the App Store workflow. See `scripts/xcode-cloud-build.sh --help`
[positional-arguments]
cloud-build *args:
    scripts/xcode-cloud-build.sh "$@"

# ============================================================================
# Utilities
# ============================================================================

# Remove build output
clean:
    rm -rf build WishboneKit/.build
