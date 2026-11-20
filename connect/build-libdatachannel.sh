#!/bin/sh
# Fetches and builds libdatachannel (WebRTC data channels, plus the
# WebSocket client we use for signaling) into vendor/libdatachannel.
# builtin-programs/connect.folk runs this the first time it is needed.
#
# Needs git, cmake, a C++17 compiler and the OpenSSL headers
# (sudo apt install git cmake g++ libssl-dev).
#
# Run from the root of the Folk checkout.
set -e

# The commit this was written and tested against (0.24.x).
COMMIT=a4aab41e2feb048a4abbe5f4c1d200a04c1b4d63
DIR=vendor/libdatachannel

if [ ! -d "$DIR/.git" ]; then
    git init -q "$DIR"
    git -C "$DIR" remote add origin https://github.com/paullouisageneau/libdatachannel.git
fi
git -C "$DIR" fetch -q --depth 1 origin "$COMMIT"
git -C "$DIR" checkout -q FETCH_HEAD
git -C "$DIR" submodule update -q --init --recursive --depth 1

# We only carry data, so leave out media transport (and its libsrtp
# dependency).
cmake -S "$DIR" -B "$DIR/build" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX="$PWD/$DIR/install" \
    -DUSE_GNUTLS=0 -DUSE_NICE=0 \
    -DNO_MEDIA=ON -DNO_EXAMPLES=ON -DNO_TESTS=ON
cmake --build "$DIR/build" -j "$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 2)"
cmake --install "$DIR/build"
