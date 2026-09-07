# xberg-serve

Custom Docker images for [xberg](https://github.com/xberg-io/xberg) 1.1.1
(MIT), packaged as a REST document-extraction service, published by CI to
`ghcr.io/runyournode/xberg-serve`.

| Profile | File | OCR | ML/ONNX/GPU | HEIC | Use case |
|---|---|---|---|---|---|
| `ultralight` | `docker/build/1.1.1/Dockerfile.ultralight` | no | no | yes | default — text-layer documents, HEIC images |
| `ocrlight` | `docker/build/1.1.1/Dockerfile.ocrlight` | Tesseract (dynamic) | no | yes | scanned documents, HEIC images |

Both run on CPU, with no download at runtime: everything needed (the `xberg`
binary, Tesseract language packs for `ocrlight`) is baked into the image
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

- **`ultralight`**: `--features "api,heic"` → `legacy-base` (office
  formats/PDF/email/HTML/XML/archives/sqlite/mdx/svg/wordperfect, language
  detection, chunking) + axum server + HEIC/AVIF. HEIC adds no deep
  learning at all: `libheif` is a codec (like libjpeg), packaged in Debian
  trixie (`libheif-dev`/`libheif1`), no source compile needed.
- **`ocrlight`**: `--features "api,pdf-ocr,xberg/tesseract-dynamic,heic"` →
  ultralight + Tesseract dynamically linked against the system's
  `libtesseract`/`libleptonica`, instead of compiling those from vendored
  sources (xberg's default `static-linking` behavior). Much faster to
  build, and — crucially — **rebuildable offline**, which wasn't possible
  before upstream added the `tesseract-dynamic` feature. HEIC rides along
  for free, same codec dependency as `ultralight`, no extra ML. Language
  packs (`tesseract-ocr-fra/eng/osd`) come from apt, not from an HTTP
  download we script ourselves.

The ONNX-backed OCR engines (`paddle-ocr`, `sceptre-ocr`) and the `candle-*`
VLMs stay out of scope: they resolve their models from Hugging Face on first
use, which breaks air-gapped.

## Layout

```
docker/
  compose.yaml                    # both services, ghcr.io images
  build/<version>/                # one folder per upstream xberg release
    Dockerfile.ultralight
    Dockerfile.ocrlight
  mount_config/                   # reserved (xberg has no config file today,
                                   # ready if that changes)
  mount_runtime/
    cache_ultralight/             # bind-mount -> XBERG_CACHE_DIR
    cache_ocrlight/
.github/workflows/docker-publish.yaml
VERSIONS                          # pins XBERG_VERSION -> which docker/build/<version>/ is current
scripts/
  check-features.sh               # verifies feature names exist; runs in CI before every build
  smoke.sh                        # post-deploy sanity check (manual)
```

## Local build

```bash
bash scripts/check-features.sh
docker build -f docker/build/1.1.1/Dockerfile.ultralight -t xberg-serve:ultralight .
docker build -f docker/build/1.1.1/Dockerfile.ocrlight   -t xberg-serve:ocrlight   .
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
cp .env.example .env
docker compose -f docker/compose.yaml --env-file .env up -d
```

`ultralight` on `127.0.0.1:8083`, `ocrlight` on `127.0.0.1:8084`. If the
target machine is truly air-gapped and has no access to `ghcr.io`, transfer
the image built by CI (or locally) with `docker save` / `scp` / `docker
load` — there's no scripted mechanism for that in this repo, it's a plain
standard Docker export/import.

## Hardening

Containers run `read_only`, `cap_drop: ALL`, `no-new-privileges`, a fixed
non-root UID 10001 (not a dynamic `useradd -r`: needed so the
`docker/mount_runtime/` bind-mount can be chowned reproducibly), `/tmp` on a
sized tmpfs (2 GB for ocrlight, which rasterizes pages). Proxies are cleared
and `NO_PROXY=*`: an accidental outbound call should fail immediately. The
port is published on `127.0.0.1` only. CPU/memory limits live in `.env` —
keep `XBERG_MAX_CONCURRENT` <= the number of CPUs allocated.

## To verify once built

Three things not confirmed without actually running the binary:

1. **`xberg serve` flags.** `docker run --rm xberg-serve:ultralight serve
   --help`. `--host`/`--port` are assumed; adjust `CMD` and `command:` if
   they differ.
2. **The real health endpoint.** `scripts/smoke.sh` reads `/openapi.json`.
   The current `healthcheck` uses `xberg --version` in the meantime —
   swap it for the real endpoint once known.
3. **`ocrlight`'s dynamic linkage.** `docker run --rm xberg-serve:ocrlight
   cat /usr/local/share/xberg/ldd.txt` — confirms everything resolves; the
   build already fails on its own if a `.traineddata` file or a library is
   missing (see the guard `RUN` steps in the Dockerfile), but it's worth
   checking `TESSDATA_PREFIX` in practice against a real scanned document.

## markgate integration

xberg exposes its own REST contract, not the `PUT /process` returning
`{page_content, metadata}` expected by Open WebUI's External Document
Loader. The adapter lives on the markgate side, same as for foil-serve.
Suggested routing: text-layer PDFs + office formats + HEIC → `ultralight`;
scanned PDFs / images → `ocrlight`; tables / complex layouts →
`foil-serve`. Switchover threshold: xberg treats a document as "scanned"
below roughly 64 total non-whitespace characters and 32 per page on
average — implementing that check in markgate avoids an unnecessary
round-trip.
