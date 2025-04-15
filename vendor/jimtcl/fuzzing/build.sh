#!/bin/bash

DIR=$(pwd)

# make sure jim is up to date
cd ..
make
cd $DIR

# build
clang -fsanitize=fuzzer,undefined,address -g jim-fuzz.c ../libjim.a -o jim-fuzzer -lm -lssl -lcrypto -lz