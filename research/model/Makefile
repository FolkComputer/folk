# Checks Folk.tla with TLC. Needs Java and tla2tools.jar (see ../setup.sh).
#
#   make -C research/model          # all four models, then the figure
#
# MC_Chain and MC_RaceAtomic must pass. MC_Cycle and MC_Race must fail, on
# AgreesWithDatalog and AtMostOnce respectively: the traces TLC prints are
# the point of those two models.

TLA2TOOLS ?= /opt/ft/tla2tools.jar
JIMSH := ../../vendor/jimtcl/jimsh
TLC := java -XX:+UseParallelGC -cp $(TLA2TOOLS) tlc2.TLC -workers 1 -deadlock \
	-nowarning -noGenerateSpecTE -metadir /tmp/tlc-meta
QUIET := grep -v 'Picked up\|^Linting\|^Semantic\|^Parsing\|^Starting\|^Running\|^Implied\|^Computing\|^Finished computing\|^TLC2 Version\|^Progress\|^Finished in'

.PHONY: all check figure
all: check figure

check:
	mkdir -p out
	$(TLC) -config MC_Chain.cfg MC_Chain.tla | $(QUIET) > out/MC_Chain.txt; \
		grep -q 'No error has been found' out/MC_Chain.txt
	$(TLC) -config MC_RaceAtomic.cfg MC_Race.tla | $(QUIET) > out/MC_RaceAtomic.txt; \
		grep -q 'No error has been found' out/MC_RaceAtomic.txt
	$(TLC) -config MC_Cycle.cfg MC_Cycle.tla | $(QUIET) > out/MC_Cycle.txt; \
		grep -q 'Invariant AgreesWithDatalog is violated' out/MC_Cycle.txt
	$(TLC) -config MC_Race.cfg MC_Race.tla | $(QUIET) > out/MC_Race.txt; \
		grep -q 'Invariant AtMostOnce is violated' out/MC_Race.txt
	@echo "models behave as documented"

figure:
	mkdir -p out
	$(TLC) -config MC_Tiny.cfg -dump dot,actionlabels out/MC_Tiny.dot MC_Tiny.tla | $(QUIET) | tail -3
	$(JIMSH) pretty-dot.tcl out/MC_Tiny.dot out/lifecycle.dot
	rm -f out/MC_Tiny.dot
	dot -Tsvg out/lifecycle.dot -o out/lifecycle.svg
