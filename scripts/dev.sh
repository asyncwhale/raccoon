#!/usr/bin/env bash
set -euo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
    echo "Usage: $0 <command>"
    echo ""
    echo "Commands:"
    echo "  gen        Run xcodegen generate"
    echo "  core-test  Run swift test in RaccoonCore"
    echo "  build      Build the Raccoon app with xcodebuild"
    exit 1
}

cmd="${1:-}"

case "$cmd" in
    gen)
        cd "$REPO_ROOT"
        xcodegen generate
        ;;
    core-test)
        cd "$REPO_ROOT/RaccoonCore"
        swift test
        ;;
    build)
        cd "$REPO_ROOT"
        xcodebuild \
            -project Raccoon.xcodeproj \
            -scheme Raccoon \
            -destination 'platform=macOS' \
            build
        ;;
    *)
        usage
        ;;
esac
