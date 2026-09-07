#!/usr/bin/env bash
# [connected] Verify the feature names this project builds on actually exist in
# the pinned version, BEFORE spending a build on something that would fail at
# the very last step.
#
# Why not `cargo info`: it only prints features that are enabled (default plus
# whatever they pull in transitively) and collapses the rest into a "N deactivated
# features" line. `api`, `heic`, `pdf-ocr` are all off by default, so they are
# exactly the ones it hides. This reads the published manifest instead.
set -euo pipefail

cd "$(dirname "$0")/.."
set -a
# shellcheck source=VERSIONS
. ./VERSIONS
set +a

REQUIRED_CLI="api heic pdf-ocr"
REQUIRED_CORE="tesseract-dynamic"
CACHE=$(mktemp -d)
trap 'rm -rf "$CACHE"' EXIT

fetch_manifest() {
    local crate="$1" version="$2"
    curl -fsSL "https://static.crates.io/crates/${crate}/${crate}-${version}.crate" \
      | tar xzO "${crate}-${version}/Cargo.toml"
}

feature_names() {
    awk '/^\[features\]/{f=1;next} f&&/^\[/{exit} f&&/^[a-zA-Z0-9_-]+ *=/{sub(/ *=.*/,"");print}'
}

feature_body() {
    # Print the definition of one feature, whether it is written inline or as a
    # multi-line array.
    local name="$1"
    awk -v want="$name" '
        /^\[features\]/{f=1;next}
        f&&/^\[/{exit}
        f&&$0 ~ "^"want" *=" {print; if ($0 ~ /\]/) exit; inarr=1; next}
        inarr {print; if ($0 ~ /^\]/) exit}
    '
}

check_crate() {
    local crate="$1" outfile="$2" required="$3"
    echo "== ${crate} ${XBERG_VERSION} :: features required by this project"
    if ! fetch_manifest "${crate}" "${XBERG_VERSION}" > "${outfile}"; then
        echo "  could not fetch the manifest -- no network, or version ${XBERG_VERSION} does not exist" >&2
        exit 1
    fi
    local missing=0
    for feat in ${required}; do
        if feature_names < "${outfile}" | grep -qx "${feat}"; then
            printf '  ok       %-18s = %s\n' "${feat}" \
              "$(feature_body "${feat}" < "${outfile}" | tr -d '\n ' | sed "s/^${feat}=//")"
        else
            printf '  MISSING  %s\n' "${feat}"
            missing=1
        fi
    done
    echo
    return "${missing}"
}

status=0
check_crate xberg-cli "${CACHE}/cli.toml" "${REQUIRED_CLI}" || status=1
check_crate xberg     "${CACHE}/core.toml" "${REQUIRED_CORE}" || status=1

echo "== the expensive features we deliberately leave OFF"
echo "  (all of these are in xberg-cli's default set -- hence --no-default-features)"
for feat in ocr paddle-ocr candle-vlm-ocr layout-detection embeddings chunking-tokenizers tree-sitter liter-llm; do
    feature_names < "${CACHE}/cli.toml" | grep -qx "${feat}" && printf '  off      %s\n' "${feat}"
done

if [ "${status}" -ne 0 ]; then
    echo
    echo "One or more feature names changed in ${XBERG_VERSION}." >&2
    echo "Fix the --features arguments in docker/build/${XBERG_VERSION}/Dockerfile.*" >&2
    echo "before building, or the build fails after compiling every dependency." >&2
    exit 1
fi

echo
echo "Feature names check out. Safe to build docker/build/${XBERG_VERSION}/Dockerfile.*"
