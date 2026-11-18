# Checks of the C runtime that do not need a running Folk. Run from the
# repository root:
#
#   make -C research/verify stbds-race
#   make -C research/verify cbmc
#   make -C research/verify/genmc

ROOT := ../..

.PHONY: stbds-race cbmc
stbds-race:
	printf '#define STB_DS_IMPLEMENTATION\n#include "vendor/stb_ds.h"\n' > /tmp/stbds_impl.c
	cc -O2 -w -I$(ROOT) -c -o /tmp/stbds_impl.o /tmp/stbds_impl.c
	cc -O2 -w -I$(ROOT) -o /tmp/stbds_race stbds_race.c /tmp/stbds_impl.o -lpthread
	/tmp/stbds_race

# Bounded check of trieScanVariable. CBMC reports the out-of-bounds write
# and exits non-zero; that is the expected result until the code is fixed.
cbmc:
	cbmc -I$(ROOT) -I$(ROOT)/vendor/jimtcl --function main --bounds-check --pointer-check \
		--unwind 112 cbmc_scanvariable.c 2>&1 | grep -E ': FAILURE|^\*\* |VERIFICATION' 
