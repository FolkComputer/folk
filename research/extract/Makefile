# Static analysis of Folk programs. Run from the repository root:
#
#   make -C research/extract            # analyse the tree, write research/out
#   make -C research/extract difftest   # check the parser against Jim's
#
# Needs vendor/jimtcl built (`make deps` at the root) and Graphviz for the
# .svg files.

ROOT := ../..
JIMSH := $(ROOT)/vendor/jimtcl/jimsh
OUT := $(ROOT)/research/out
SOURCES := $(shell cd $(ROOT) && find . -path ./vendor/tracy -prune -o -path ./.git -prune \
	-o -path ./research/out -prune -o \( -name '*.folk' -o -name '*.tcl' \) -print)

.PHONY: all analyze graphs difftest clean
all: analyze graphs

analyze:
	cd $(ROOT) && vendor/jimtcl/jimsh research/extract/analyze.tcl -root . -out research/out

graphs: analyze
	for g in subsystems programs rules; do \
		dot -Tsvg $(OUT)/$$g.dot -o $(OUT)/$$g.svg; \
	done

# The oracle compiles jim.c into itself to reach the static tokenizer, so
# it must be built with the flags libjim was built with.
oracle: oracle.c $(ROOT)/vendor/jimtcl/libjim.a
	cc -O1 -g -w -I $(ROOT)/vendor/jimtcl -DUSE_UTF8 -DHAVE_OPENPTY -D_GNU_SOURCE \
		-o $@ oracle.c $(ROOT)/vendor/jimtcl/libjim.a -lm -lssl -lcrypto -lz

difftest: oracle
	cd $(ROOT) && vendor/jimtcl/jimsh research/extract/difftest.tcl $(SOURCES)

clean:
	rm -f oracle
