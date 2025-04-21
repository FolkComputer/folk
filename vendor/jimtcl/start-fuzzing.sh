#!/bin/bash

afl-fuzz -i fuzzing-corpus -o fuzzing-output -- ./jimsh @@
