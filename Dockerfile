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
ARG QT_ARCH=
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
  # Dependencies
  gamemode-dev libgamemode0 libgl1-mesa-dev \
  # Qt runtime requirements
  libglib2.0-0t64 libxkbcommon0 libgl1 libegl1 fontconfig \
  # Tooling
  git unzip zip locales python3-pip

# Setup UTF-8 locale (required by aqtinstall)
RUN echo "C.UTF-8 UTF-8" > /etc/locale.gen && locale-gen
ENV LC_ALL=C.UTF-8

# Prepare and install Qt
RUN pip3 install --break-system-packages aqtinstall
RUN aqt install-qt \
  ${QT_HOST} ${QT_TARGET} ${QT_VERSION} ${QT_ARCH} \
  --outputdir /opt/qt \
  --modules qtimageformats qtnetworkauth

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
COPY <<'EOF' /usr/local/bin/build-prism.sh
#!/usr/bin/env bash
set -euo pipefail

SRC_DIR="${SRC_DIR:-/work}"
BUILD_DIR="${BUILD_DIR:-${SRC_DIR}/build-linux}"
BUILD_TYPE="${BUILD_TYPE:-Release}"

cd "$SRC_DIR"

# Fetch git submodules if they are missing (libnbtplusplus is required to build)
if [ ! -f libraries/libnbtplusplus/CMakeLists.txt ]; then
  echo "==> Initializing git submodules..."
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
RUN chmod +x /usr/local/bin/build-prism.sh

WORKDIR /work

ENTRYPOINT ["/usr/local/bin/build-prism.sh"]
