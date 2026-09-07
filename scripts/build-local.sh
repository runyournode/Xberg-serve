#!/usr/bin/env bash
# Build one or both profiles locally, exactly the way CI does (same
# Dockerfile, same context) -- for testing a change before pushing.
#
#   scripts/build-local.sh              # both profiles
#   scripts/build-local.sh ultralight   # one profile
#   scripts/build-local.sh ocrlight
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck source=VERSIONS
. ./VERSIONS
set +a

PROFILES=("$@")
[ ${#PROFILES[@]} -eq 0 ] && PROFILES=(ultralight ocrlight)

for profile in "${PROFILES[@]}"; do
    dockerfile="docker/build/${XBERG_VERSION}/Dockerfile.${profile}"
    if [ ! -f "$dockerfile" ]; then
        echo "no such Dockerfile: ${dockerfile}" >&2
        exit 2
    fi
    echo "==> building xberg-serve:${profile} from ${dockerfile}"
    docker build -f "$dockerfile" -t "xberg-serve:${profile}" .
done

echo
echo "Built: $(printf 'xberg-serve:%s ' "${PROFILES[@]}")"
echo "Try:   docker run --rm xberg-serve:ultralight serve --help"
