#!/bin/zsh
set -euo pipefail

YUEDU_PROJECT_ROOT="${0:A:h:h}"
cd "$YUEDU_PROJECT_ROOT"
YUEDU_RUN_DIR="$YUEDU_PROJECT_ROOT/build/validation/runs/$(date +%Y%m%d-%H%M%S)-$$"
mkdir -p "$YUEDU_RUN_DIR"
print -r -- '{"managedBy":"yuedu_test.sh"}' > "$YUEDU_RUN_DIR/yuedu-validation.json"
print -r -- "$$" > "$YUEDU_RUN_DIR/active.pid"

function yuedu_finish {
    local yuedu_exit=$?
    print -r -- "$yuedu_exit" > "$YUEDU_RUN_DIR/exit-code.txt"
    rm -f "$YUEDU_RUN_DIR/active.pid"
    python3 scripts/yuedu_clean_artifacts.py --apply
    print -r -- "Validation output: $YUEDU_RUN_DIR"
}
trap yuedu_finish EXIT

# A separate simulator prevents test reset arguments from clearing the user's library.
if [[ -z "${YUEDU_TEST_DEVICE_ID:-}" ]]; then
    YUEDU_TEST_DEVICE_ID=$(xcrun simctl list devices available -j | python3 -c 'import json,sys; print(next((d["udid"] for ds in json.load(sys.stdin)["devices"].values() for d in ds if d["name"] == "Yuedu Experience Tests"), ""))')
    if [[ -z "$YUEDU_TEST_DEVICE_ID" ]]; then
        YUEDU_TEST_DEVICE_ID=$(xcrun simctl create "Yuedu Experience Tests" com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro)
    fi
fi

xcodebuild -project Yuedu.xcodeproj -scheme Yuedu \
    -destination "platform=iOS Simulator,id=$YUEDU_TEST_DEVICE_ID" \
    -derivedDataPath build/validation/DerivedData \
    -resultBundlePath "$YUEDU_RUN_DIR/Tests.xcresult" \
    -parallel-testing-enabled NO "$@" test \
    > "$YUEDU_RUN_DIR/xcodebuild.log" 2>&1
