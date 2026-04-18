# camofox-browser — builds natively on linux/amd64 AND linux/arm64
# (Oracle Ampere A1, AWS Graviton, Raspberry Pi 5, Apple Silicon via buildx)
#
# Standalone build (no Make required — downloads binaries inside the build):
#   docker build -t camofox-browser:local .
#
# Fast iterative build (pre-download binaries once to dist/ with `make fetch`):
#   make build        # auto-detects arch from uname -m
#   make build-arm64  # explicit arm64

FROM node:20-bookworm-slim

# BuildKit supplies TARGETARCH automatically: "amd64" on x86_64, "arm64" on Ampere/Graviton.
# No --build-arg needed; override with --build-arg TARGETARCH=arm64 if required.
ARG TARGETARCH

# Camoufox version — bump both together when upgrading
ARG CAMOUFOX_VERSION=135.0.1
ARG CAMOUFOX_RELEASE=beta.24

# Install Firefox runtime dependencies + Xvfb virtual display
# Package names are correct for Debian bookworm (node:20-bookworm-slim).
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Firefox/Camoufox runtime
    libgtk-3-0 \
    libdbus-glib-1-2 \
    libxt6 \
    libasound2 \
    libx11-xcb1 \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxss1 \
    libxtst6 \
    # Mesa OpenGL/EGL for WebGL support (software rendering via llvmpipe).
    # Without these Firefox cannot create WebGL contexts — a major bot-detection signal.
    libegl1-mesa \
    libgl1-mesa-dri \
    libgbm1 \
    # Xvfb virtual display — lets Camoufox run as if on a real desktop
    xvfb \
    # Fonts
    fonts-liberation \
    fonts-noto-color-emoji \
    fontconfig \
    # Utils
    ca-certificates \
    curl \
    unzip \
    # yt-dlp & better-sqlite3 build dependencies
    python3 \
    make \
    g++ \
    build-essential \
    && rm -rf /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# Install Camoufox browser binary + yt-dlp
#
# Fast path: bind-mount pre-downloaded files from dist/ (populated by `make fetch`).
#   → Uses cached files; build takes ~30 s.
# Fallback: if dist/ is empty or has wrong-arch files, downloads directly.
#   → Works on a fresh clone with nothing in dist/; build takes ~5 min (network).
#
# TARGETARCH → upstream suffix mapping:
#   amd64 → camoufox-x86_64.zip  /  yt-dlp_linux       (no suffix)
#   arm64 → camoufox-aarch64.zip /  yt-dlp_linux_aarch64
# ---------------------------------------------------------------------------
RUN --mount=type=bind,source=dist,target=/dist \
    set -eu; \
    # Map Docker TARGETARCH to upstream naming conventions
    case "${TARGETARCH:-}" in \
      arm64)       ARCH=aarch64; CAMOUFOX_ARCH=arm64;  YTDLP_ARCH=_aarch64 ;; \
      amd64|"")    ARCH=x86_64;  CAMOUFOX_ARCH=x86_64; YTDLP_ARCH=""       ;; \
      *)           echo "Unsupported TARGETARCH: ${TARGETARCH}"; exit 1      ;; \
    esac; \
    \
    CAMOUFOX_ZIP="/dist/camoufox-${ARCH}.zip"; \
    YTDLP_BIN="/dist/yt-dlp-${ARCH}"; \
    CAMOUFOX_URL="https://github.com/daijro/camoufox/releases/download/v${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}/camoufox-${CAMOUFOX_VERSION}-${CAMOUFOX_RELEASE}-lin.${CAMOUFOX_ARCH}.zip"; \
    YTDLP_URL="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_linux${YTDLP_ARCH}"; \
    \
    # --- Camoufox ---
    mkdir -p /root/.cache/camoufox; \
    if [ -f "${CAMOUFOX_ZIP}" ]; then \
        echo "Using pre-downloaded Camoufox from dist/"; \
        (unzip -q "${CAMOUFOX_ZIP}" -d /root/.cache/camoufox || true); \
    else \
        echo "dist/camoufox-${ARCH}.zip not found — downloading from GitHub..."; \
        curl -fSL "${CAMOUFOX_URL}" -o /tmp/camoufox.zip; \
        (unzip -q /tmp/camoufox.zip -d /root/.cache/camoufox || true); \
        rm -f /tmp/camoufox.zip; \
    fi; \
    chmod -R 755 /root/.cache/camoufox; \
    echo "{\"version\":\"${CAMOUFOX_VERSION}\",\"release\":\"${CAMOUFOX_RELEASE}\"}" > /root/.cache/camoufox/version.json; \
    test -f /root/.cache/camoufox/camoufox-bin && echo "Camoufox installed OK" || (echo "ERROR: camoufox-bin not found after install"; exit 1); \
    \
    # --- yt-dlp ---
    if [ -f "${YTDLP_BIN}" ]; then \
        echo "Using pre-downloaded yt-dlp from dist/"; \
        install -m 755 "${YTDLP_BIN}" /usr/local/bin/yt-dlp; \
    else \
        echo "dist/yt-dlp-${ARCH} not found — downloading from GitHub..."; \
        curl -fSL "${YTDLP_URL}" -o /usr/local/bin/yt-dlp; \
        chmod 755 /usr/local/bin/yt-dlp; \
    fi; \
    echo "yt-dlp installed OK"

WORKDIR /app

COPY package.json ./

# NPM_CONFIG_IGNORE_SCRIPTS suppresses `postinstall: npx camoufox-js fetch`
# (we already baked the correct-arch binary above; the fetch is wasteful + wrong-arch).
RUN NPM_CONFIG_IGNORE_SCRIPTS=true npm install --omit=dev
RUN npm rebuild better-sqlite3

COPY server.js ./
COPY lib/ ./lib/

ENV NODE_ENV=production
ENV CAMOFOX_PORT=9377

EXPOSE 9377

CMD ["sh", "-c", "node --max-old-space-size=${MAX_OLD_SPACE_SIZE:-128} server.js"]