#!/bin/sh
# Installs the tools the research/ directory uses, on Ubuntu 24.04.
# This is what was run on the cloud VM (4 vCPU, 15 GB, kernel 6.18) to
# produce the files under research/out and the numbers in FINDINGS.md.
#
#   sudo sh research/setup.sh        # from the repository root
#
# Everything outside apt goes under $PREFIX (default /opt/ft).
set -e
PREFIX=${PREFIX:-/opt/ft}
mkdir -p "$PREFIX"

apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
    graphviz \
    default-jre-headless \
    cbmc \
    linux-tools-generic linux-tools-common \
    google-perftools libgoogle-perftools-dev elfutils \
    automake libtool autoconf-archive libssl-dev zlib1g-dev \
    libdbus-1-dev libtbb-dev libfreetype-dev \
    clang-19 llvm-19-dev g++-14 libedit-dev libffi-dev bc cmake git curl
# graphviz                 dot, for every figure
# default-jre-headless     TLC
# cbmc                     bounded checks of trie.c
# linux-tools-*            perf (`make flamegraph` uses it)
# google-perftools         the heap profiler behind `make heapprofile-remote`
# automake .. zlib1g-dev   Folk's own build, and vendor/wslay for the web server
# libdbus .. libfreetype   needed to configure Tracy's capture tools
# clang-19 .. bc           GenMC

# Folk itself, and the Tracy sources the Makefile expects in vendor/tracy.
git submodule update --init --depth 1 vendor/tracy
make deps
make

# perf: the linux-tools wrapper refuses to run on a kernel it has no
# package for. The binary itself works, with software events.
ln -sf "$(ls /usr/lib/linux-tools/*/perf | tail -1)" "$PREFIX/perf"

# FlameGraph, as used by `make flamegraph`.
[ -d "$PREFIX/FlameGraph" ] ||
    git clone -q --depth 1 https://github.com/brendangregg/FlameGraph.git "$PREFIX/FlameGraph"

# Tracy's headless capture and CSV export, built from the vendored
# checkout so the protocol version matches the client in the folk binary.
for tool in capture csvexport; do
    [ -x "$PREFIX/tracy-$tool/tracy-$tool" ] && continue
    cmake -S vendor/tracy/$tool -B "$PREFIX/tracy-$tool" \
        -DCMAKE_BUILD_TYPE=Release -DNO_ISA_EXTENSIONS=ON > /dev/null
    cmake --build "$PREFIX/tracy-$tool" -j2 > /dev/null
done

# TLA+ tools.
[ -f "$PREFIX/tla2tools.jar" ] ||
    curl -sSL -o "$PREFIX/tla2tools.jar" \
        https://github.com/tlaplus/tlaplus/releases/download/v1.8.0/tla2tools.jar

# GenMC 0.20 supports LLVM 19 to 22; Ubuntu 24.04's default is 18.
if [ ! -x "$PREFIX/genmc/build/bin/genmc" ]; then
    [ -d "$PREFIX/genmc" ] ||
        git clone -q --depth 1 https://github.com/MPI-SWS/genmc.git "$PREFIX/genmc"
    CC=gcc-14 CXX=g++-14 cmake -S "$PREFIX/genmc" -B "$PREFIX/genmc/build" \
        -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/usr/lib/llvm-19 > /dev/null
    cmake --build "$PREFIX/genmc/build" -j2 > /dev/null
fi

# Instrumented builds of folk, next to the normal one.
research/verify/build-variant.sh tsan -fsanitize=thread
research/verify/build-variant.sh asan -fsanitize=address,undefined -fsanitize-recover=address
research/verify/build-variant.sh tracy -DTRACY_ENABLE

echo "tools are in $PREFIX"
