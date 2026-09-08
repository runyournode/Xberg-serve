# xberg-serve

Custom Docker images for [xberg](https://github.com/xberg-io/xberg) 1.1.1
(MIT), packaged as a REST document-extraction service, published by CI to
`ghcr.io/runyournode/xberg-serve`.

| Profile | File | OCR | ML/ONNX/GPU | HEIC | Runtime base | Use case |
|---|---|---|---|---|---|---|
| `ultralight` | `docker/build/1.1.1/Dockerfile.ultralight` | no | no | no | distroless (no shell, no package manager) | default — text-layer documents |
| `ocrlight` | `docker/build/1.1.1/Dockerfile.ocrlight` | Tesseract (dynamic) | no | yes | `debian:trixie-slim` | scanned documents, HEIC images |

Both run on CPU, with no download at runtime: everything needed (the `xberg`
binary, Tesseract language packs for `ocrlight` (fra+eng)) is baked into the image
layer during `docker build`, on the CI runner that has internet access — not
on the target machine.

## Why not the official Dockerfiles as-is

xberg's own [`docker/` folder](https://github.com/xberg-io/xberg/tree/main/docker)
(`Dockerfile.core`/`.full`) always compiles `xberg-cli --features all`: OCR +
ONNX Runtime + candle + libheif + pdfium, ~1 GB, no "no-ML" variant. We reuse
its conventions (`trixie` base, `tini` as PID 1, non-root user,
`HEALTHCHECK`) but not the feature set: both profiles here use
`cargo install xberg-cli --no-default-features --features ...` to control
exactly what gets compiled, instead of cloning the whole monorepo.

- **`ultralight`**: `--features api` → `legacy-base` (office
  formats/PDF/email/HTML/XML/archives/sqlite/mdx/svg/wordperfect, language
  detection, chunking) + axum server. Its runtime stage is
  [distroless](https://github.com/GoogleContainerTools/distroless)
  (`gcr.io/distroless/cc-debian13:nonroot`, same Debian release as the
  builder so no glibc mismatch): no shell, no `apt`, no CLI binaries beyond
  `xberg` itself and a statically-linked `tini`. Every `.so` the binary
  actually links is extracted from the builder stage by path and `COPY`'d
  in — there's no shell in the final stage to install anything itself.
  `heic` was tried here and dropped: confirmed locally that `xberg` routes
  every raster image through its OCR pipeline (`xberg formats` never lists
  `.heic`/`.jpg`/`.png`, only vector `.svg`), so decoding HEIC without an
  OCR backend compiled in has nothing to feed it — `extract` on a real
  `.heic` file returned `Unsupported format: image/heif` even with the
  codec linked and its plugin loading correctly. HEIC only earns its keep
  in `ocrlight`, below.
- **`ocrlight`**: `--features "api,pdf-ocr,xberg/tesseract-dynamic,heic"` →
  ultralight + Tesseract dynamically linked against the system's
  `libtesseract`/`libleptonica`, instead of compiling those from vendored
  sources (xberg's default `static-linking` behavior). Much faster to
  build, and — crucially — **rebuildable offline**, which wasn't possible
  before upstream added the `tesseract-dynamic` feature. HEIC here actually
  works (an OCR backend exists to consume the decoded image) — confirmed
  locally with `xberg doctor`, which reports Tesseract 5.5.0 and the
  `tessdata` path. `libheif` is a codec (like libjpeg), packaged in Debian
  trixie (`libheif-dev`/`libheif1`), no source compile needed, no deep
  learning. Language packs (`tesseract-ocr-fra/eng/osd`) come from apt, not
  from an HTTP download we script ourselves.

The ONNX-backed OCR engines (`paddle-ocr`, `sceptre-ocr`) and the `candle-*`
VLMs stay out of scope: they resolve their models from Hugging Face on first
use, which breaks air-gapped.

## Layout

```
docker/
  compose.yaml                    # both services, ghcr.io images
  healthcheck.rs                  # dependency-free /health prober, compiled into both images
  build/<version>/                # one folder per upstream xberg release
    Dockerfile.ultralight
    Dockerfile.ocrlight
  mount_config/                   # ultralight.toml, ocrlight.toml -- each mounted
                                   # read-only at /config/config.toml (serve --config)
  mount_runtime/
    cache_ultralight/             # bind-mount -> XBERG_CACHE_DIR
    cache_ocrlight/
.github/workflows/docker-publish.yaml
VERSIONS                          # pins XBERG_VERSION -> which docker/build/<version>/ is current
scripts/
  check-features.sh               # verifies feature names exist; runs in CI before every build
  build-local.sh                  # build one/both profiles locally, same Dockerfiles as CI
  smoke.sh                        # post-deploy sanity check (manual)
```

## Local build

```bash
bash scripts/check-features.sh
bash scripts/build-local.sh              # both profiles
bash scripts/build-local.sh ultralight   # or just one
```

## CI

`.github/workflows/docker-publish.yaml` builds and pushes both images on
push (`main`, `dev`) and on `vX.Y.Z` tags, to:

```
ghcr.io/runyournode/xberg-serve:<tag>-ultralight
ghcr.io/runyournode/xberg-serve:<tag>-ocrlight
```

A `check-features` job runs `scripts/check-features.sh` first and blocks
the build if a pinned Cargo feature no longer exists upstream — fails fast
instead of burning CI minutes on a `cargo install` doomed to fail at the
last step. The `build` job then reads `XBERG_VERSION` from `VERSIONS` to
know which `docker/build/<version>/` folder to build. Moving to a new
xberg version means adding a new `docker/build/<version>/` folder with its
two Dockerfiles, and updating `VERSIONS`.

## Running it

```bash
docker compose -f docker/compose.yaml up -d
```

`ultralight` on `127.0.0.1:8083`, `ocrlight` on `127.0.0.1:8084`. If the
target machine is truly air-gapped and has no access to `ghcr.io`, transfer
the image built by CI (or locally) with `docker save` / `scp` / `docker
load` — there's no scripted mechanism for that in this repo, it's a plain
standard Docker export/import.

## Hardening

Both images: `read_only`, `cap_drop: ALL`, `no-new-privileges`, `/tmp` on a
sized tmpfs (2 GB for ocrlight, which rasterizes pages), proxies cleared
with `NO_PROXY=*` so an accidental outbound call fails immediately instead
of hanging, port published on `127.0.0.1` only (`ocrlight`; `ultralight`
publishes on all interfaces — see `docker/compose.yaml`). Memory limits are
literal per-service values in `docker/compose.yaml`'s
`deploy.resources.limits`; CPU/concurrency is governed instead by
`[concurrency].max_threads`, set explicitly per profile in
`docker/mount_config/<profile>.toml`.

Beyond that, the two profiles harden differently because their runtime
bases differ:

- **`ultralight`** is distroless: no shell, no package manager, no apt
  sources to begin with, no CLI binaries beyond `xberg` and a static
  `tini`. Runs as the distroless base's own fixed non-root user, uid/gid
  **65532** (not a `useradd`d one — there's no shell to run `useradd` in).
  Chown the bind-mount before first run:
  `chown -R 65532:65532 docker/mount_runtime/cache_ultralight`.
- **`ocrlight`** stays Debian-based (`debian:trixie-slim`) since Tesseract/
  Leptonica's own dependency chain and the `libheif` plugin `dlopen()`
  gotcha (see above) make a from-scratch distroless conversion riskier to
  get right without a local test loop — deferred, not ruled out. It still
  installs `libtesseract5`/`libleptonica6` directly instead of the full
  `tesseract-ocr` CLI package: `xberg` links the library, never shells out
  to the `tesseract` binary, so the CLI package would only add ~15 unused
  binaries and an unrelated font-rendering tail
  (cairo/pango/fontconfig/ICU). **Correction after actually inspecting the
  built image's `ldd.txt`**: `libcurl` (and its own large dependency tree —
  libssl, libgnutls, libldap, libkrb5, libssh2...) is *not* removed by that
  change — it turns out to be a hard `Depends` of `libtesseract5` itself,
  not just of the CLI package. It ships in the image either way, unused by
  `xberg`'s own code paths, mitigated the same way as everything else here
  (`NO_PROXY=*`, `read_only`, `cap_drop: ALL`) rather than actually absent.
  `/etc/apt/sources.list*` is cleared after install, so even if `apt`/`dpkg`
  themselves are still present, there's nothing configured left to fetch
  from. Runs as a fixed non-root UID **10001** (`useradd --system`, not a
  dynamic one, so the bind-mount stays chownable):
  `chown -R 10001:10001 docker/mount_runtime/cache_ocrlight`.

## To verify once built

`scripts/build-local.sh` builds either or both profiles locally (same
Dockerfiles CI uses) — use it before pushing when changing a Dockerfile,
rather than guessing and waiting on a CI round-trip.

Confirmed locally already:

- **`xberg serve` flags**: `--host`/`-H`, `--port`/`-p`, `--log-level`,
  `--config` — `docker run --rm xberg-serve:ultralight serve --help`.
- **`--config` cannot carry `[server]`.** Tried mounting a `config.toml`
  with both `[server]` and `[concurrency]` (the "nested format" the docs
  describe) and running `serve --config` against it: fails outright —
  `serve` also loads the same file as xberg's *extraction* config, which
  `deny_unknown_fields`-rejects the top-level `server` key it doesn't
  recognize. `mount_config/<profile>.toml` therefore holds `[concurrency]`
  only; host/port stay `serve` CLI flags and CORS/upload limits stay env
  vars (`XBERG_MAX_REQUEST_BODY_BYTES`/`XBERG_MAX_MULTIPART_FIELD_BYTES` in
  `docker/compose.yaml`).
- **`ultralight`'s distroless conversion actually starts**: `serve --help`
  and `--version` both run cleanly with no shared-library errors — the
  copied `.so` closure and static `tini` resolve correctly.
- **`ocrlight`'s Tesseract detection**: `docker run --rm xberg-serve:ocrlight
  doctor` reports `tesseract 5.5.0; tessdata for ... language(s) at
  /usr/share/tesseract-ocr/5/tessdata` — the dynamic-linking build and the
  language packs both resolve as intended.
- **`xberg-healthcheck` against a real running server.** Built `ultralight`
  locally, ran it with the real `mount_config/ultralight.toml` +
  `serve --host --port --config` command from `compose.yaml`: `docker
  inspect --format='{{.State.Health.Status}}'` reports `healthy`, `docker
  exec ... /usr/local/bin/xberg-healthcheck` exits `0`, and `curl
  /health` from the host returns `200` with the real JSON payload
  (`{"status":"healthy",...}`). `ldd` on the compiled binary shows only
  `libc`/`libgcc_s`/the loader — nothing the distroless base doesn't
  already ship.

Still open:

1. **`xberg-healthcheck` reporting unhealthy.** Confirmed it reports
   `healthy` against a live server (above); haven't yet confirmed it flips
   to `unhealthy` if `xberg serve` dies inside the container while `tini`
   stays up.
2. **A real end-to-end extraction call** (`POST /extract` via `serve`,
   rather than the CLI's `extract`/`doctor`) against both profiles, ideally
   with `tests/corpus/` populated so `scripts/smoke.sh` has something to
   check beyond `/openapi.json`.

## markgate integration

xberg exposes its own REST contract, not the `PUT /process` returning
`{page_content, metadata}` expected by Open WebUI's External Document
Loader. The adapter lives on the markgate side, same as for foil-serve.
Suggested routing: text-layer PDFs + office formats → `ultralight`;
scanned PDFs / images (including HEIC) → `ocrlight`; tables / complex
layouts → `foil-serve`. Switchover threshold: xberg treats a document as "scanned"
below roughly 64 total non-whitespace characters and 32 per page on
average — implementing that check in markgate avoids an unnecessary
round-trip.
