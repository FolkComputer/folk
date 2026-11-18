# Bounded model checking of the lock-free parts of the runtime with GenMC
# (see ../../setup.sh). Run from this directory:
#
#   make            # both harnesses must end with "No errors were detected."

GENMC ?= /opt/ft/genmc/build/bin/genmc
ROOT := ../../..

.PHONY: all workqueue genrc clean
all: workqueue genrc

workqueue:
	$(GENMC) -- -I$(ROOT) -I$(ROOT)/vendor/jimtcl workqueue_harness.c | tail -5

# The GenRc type and its three functions, verbatim from db.c.
genrc_extract.h: $(ROOT)/db.c
	sed -n '/^typedef struct GenRc {/,/^\/\/ Destructor datatype:/p' $< | sed '$$d' > $@

genrc: genrc_extract.h
	$(GENMC) -- genrc_harness.c | tail -5

clean:
	rm -f genrc_extract.h
