# Dockerfile for Prism Launcher
#
# Builds the project from source when the container starts.
# The sources are mounted at runtime (no COPY of the code into the image),
# so the image can be reused across checkouts/branches.
#
# Usage:
#   docker build -t prismlauncher-build .
#   docker run --rm -v "$PWD:/work" prismlauncher-build
#
# The compiled binary will be placed in ./build-linux/prismlauncher on the host.

FROM debian:stable-slim

ARG QT_ABI=gcc_64
# aqt >= 3 uses the "linux_gcc_64" target name for Qt >= 6.9.x archives
ARG QT_TARGET_NAME=linux_gcc_64
ARG QT_HOST=linux
ARG QT_TARGET=desktop
ARG QT_VERSION=6.10.3

ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get --assume-yes upgrade

# Use Adoptium for Java 17
RUN apt-get --assume-yes --no-install-recommends install \
  apt-transport-https ca-certificates curl gpg
RUN curl -L https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor | tee /etc/apt/trusted.gpg.d/adoptium.gpg
RUN echo "deb https://packages.adoptium.net/artifactory/deb $(awk -F= '/^VERSION_CODENAME/{print$2}' /etc/os-release) main" | tee /etc/apt/sources.list.d/adoptium.list
RUN apt-get update

# Install base dependencies
RUN apt-get --assume-yes --no-install-recommends install \
  # Compilers
  gcc g++ temurin-17-jdk scdoc \
  # Build system
  cmake ninja-build pkg-config \
  # Extra CMake Modules (required: find_package(ECM REQUIRED) in CMakeLists.txt)
  extra-cmake-modules \
  # Dependencies
  libarchive-dev libtomlplusplus-dev libqrencode-dev \
  gamemode-dev libgamemode0 libgl1-mesa-dev \
  # Qt runtime requirements
  libglib2.0-0t64 libxkbcommon0 libgl1 libegl1 fontconfig \
  # Tooling
  git unzip zip locales python3-pip

# Setup UTF-8 locale (required by aqtinstall)
RUN echo "C.UTF-8 UTF-8" > /etc/locale.gen && locale-gen
ENV LC_ALL=C.UTF-8

# Prepare and install Qt
# NOTE: aqt may print "WARNING: Failed to download checksum for ... Updates.xml"
# when its mirrorbrain redirect lands on an unofficial/incomplete mirror.
# The checksum is optional; the installation still succeeds. To silence it, pin
# an official mirror with:  --base https://download.qt.io
#
# Proxy support: if your network requires a proxy (e.g. one running on the
# docker host), pass it at build time:
#   docker build -t prismlauncher-build \
#     --build-arg HTTP_PROXY=http://127.0.0.1:8888 \
#     --build-arg HTTPS_PROXY=http://127.0.0.1:8888 \
#     --network host .
# On Linux use http://host.docker.internal:8888 together with
#   --add-host=host.docker.internal:host-gateway
# or simply export HTTP(S)_PROXY in your shell (docker picks them up as defaults).
ARG HTTP_PROXY
ARG HTTPS_PROXY
ARG NO_PROXY=localhost,127.0.0.1

RUN pip3 install --break-system-packages aqtinstall
RUN aqt install-qt \
  ${QT_HOST} ${QT_TARGET} ${QT_VERSION} ${QT_TARGET_NAME} \
  -O /opt/qt \
  --base https://download.qt.io \
  --modules qtimageformats qtnetworkauth

# Build cmark from source.
# Debian's libcmark-dev is broken in slim images: its exported CMake config
# references the "/usr/bin/cmark" executable which the -dev package does not
# ship, so configure dies with:
#   The imported target "cmark::cmark_exe" references the file "/usr/bin/cmark"
#   but this file does not exist.
# Building upstream cmark with executables disabled avoids that entirely.
ARG CMARK_VERSION=0.31.2
RUN curl -fsSL "https://github.com/commonmark/cmark/archive/refs/tags/${CMARK_VERSION}.tar.gz" -o /tmp/cmark.tar.gz \
 && tar -xzf /tmp/cmark.tar.gz -C /tmp \
 && cmake -S "/tmp/cmark-${CMARK_VERSION}" -B /tmp/cmark-build -G Ninja \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMARK_TESTS=OFF \
      -DCMARK_STATIC=ON \
      -DCMARK_SHARED=ON \
      -DCMARK_LIB_EXE=OFF \
      -DCMARK_EXTENSIONS_EXE=OFF \
 && cmake --build /tmp/cmark-build -j"$(nproc)" \
 && cmake --install /tmp/cmark-build \
 && rm -rf /tmp/cmark.tar.gz "/tmp/cmark-${CMARK_VERSION}" /tmp/cmark-build

ENV PATH=/opt/qt/${QT_VERSION}/${QT_ABI}/bin:$PATH
ENV QT_PLUGIN_PATH=/opt/qt/${QT_VERSION}/${QT_ABI}/plugins/

## We don't use these. Nuke them
RUN rm -rf \
  "$QT_PLUGIN_PATH"/designer \
  "$QT_PLUGIN_PATH"/help \
  "$QT_PLUGIN_PATH"/printsupport \
  "$QT_PLUGIN_PATH"/qmllint \
  "$QT_PLUGIN_PATH"/qmlls \
  "$QT_PLUGIN_PATH"/qmltooling \
  "$QT_PLUGIN_PATH"/sqldrivers

# Cleanup
RUN apt-get --assume-yes autopurge && rm -rf /var/lib/apt/lists/*

# Build script: runs at container start, compiles the project from sources
# mounted at /work
# NOTE: heredoc content is written VERBATIM into the image file, so it must use
# Unix (LF) line endings. If your git config has core.autocrlf=true (typical on
# Windows), add a .gitattributes rule "* text=auto eol=lf" or set
# "git config core.autocrlf input" — otherwise the shebang becomes
# "#!/usr/bin/env bash\r" and the container fails with:
#   env: 'bash\r': No such file or directory
COPY <<'EOF' /usr/local/bin/build-prism.sh
#!/bin/bash
set -euo pipefail

# Self-heal: if this file somehow got Windows CRLF line endings, strip the
# carriage returns and re-exec itself.
if grep -q $'\r' "$0"; then
  sed -i 's/\r$//' "$0"
  exec bash "$0" "$@"
fi

SRC_DIR="${SRC_DIR:-/work}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build-linux}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

cd "$SRC_DIR"

# Git refuses to operate in a mounted repo owned by another uid unless told
# it is safe ("dubious ownership" error otherwise).
git config --global --add safe.directory "$SRC_DIR" || true

# The image contains no sources; everything comes from the bind mount. If /work
# is not a git checkout, the user most likely forgot "-v $PWD:/work".
if [ ! -d "$SRC_DIR/.git" ] && ! git rev-parse --git-dir >/dev/null 2>&1; then
  echo "ERROR: '$SRC_DIR' is not a git repository." >&2
  echo "" >&2
  echo "The image does NOT contain the sources — they must be mounted at runtime:" >&2
  echo '    docker run --rm -v "$PWD:/work" prismlauncher-build' >&2
  echo "" >&2
  echo "Run this from the root of your PrismLauncher clone (the directory that" >&2
  echo "contains CMakeLists.txt and .git). On SELinux systems (Fedora/RHEL)" >&2
  echo 'append :z to the volume:  -v "$PWD:/work:z"' >&2
  exit 1
fi

# Fetch git submodules if they are missing (libnbtplusplus is required to build)
if [ ! -f libraries/libnbtplusplus/CMakeLists.txt ]; then
  echo "==> Initializing git submodules..."
  # Submodules live inside the mounted tree; tell git the nested paths are safe.
  git config --global --add safe.directory '*' || true
  git submodule update --init --recursive libraries/libnbtplusplus
fi

echo "==> Configuring (${BUILD_TYPE}, generator: Ninja)..."
cmake -S . -B "$BUILD_DIR" -G Ninja \
  -DCMAKE_BUILD_TYPE="$BUILD_TYPE" \
  -DLauncher_WARNING_AS_ERROR=OFF

echo "==> Building..."
cmake --build "$BUILD_DIR" -j"$(nproc)"

echo "==> Done. Binary: $BUILD_DIR/prismlauncher"
"$BUILD_DIR/prismlauncher" --help >/dev/null 2>&1 && echo "    (binary runs OK)" || true
EOF
RUN chmod +x /usr/local/bin/build-prism.sh && \
    head -1 /usr/local/bin/build-prism.sh | od -c | head -2

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/build-prism.sh"]
