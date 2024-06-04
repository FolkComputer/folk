ifeq ($(shell uname -s),Linux)
	override CFLAGS += -Wl,--export-dynamic
endif
folk: workqueue.c db.c trie.c folk.c vendor/jimtcl/libjim.a
	cc -g -o$@ $(CFLAGS) \
		-I./vendor/libpqueue/src vendor/libpqueue/src/pqueue.c \
		-I./vendor/jimtcl -L./vendor/jimtcl \
		workqueue.c db.c trie.c folk.c \
		-ljim -lm -lssl -lcrypto -lz

.PHONY: test
test: folk
	./folk test/test.folk

debug-attach:
	lldb --attach-name folk

FOLK_REMOTE_NODE := folk-omar-mini
remote:
	rsync --delete  --include "vendor/jimtcl/*.c" --exclude "vendor/jimtcl/*" --exclude folk --timeout=5 -e "ssh -o StrictHostKeyChecking=no" -a . $(FOLK_REMOTE_NODE):~/folk2
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; sudo systemctl stop folk; killall folk; make -C vendor/jimtcl && make CFLAGS=$(CFLAGS) && ./folk'
debug-remote:
	rsync --delete  --include "vendor/jimtcl/*.c" --exclude "vendor/jimtcl/*" --exclude folk --timeout=5 -e "ssh -o StrictHostKeyChecking=no" -a . $(FOLK_REMOTE_NODE):~/folk2
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; sudo systemctl stop folk; killall folk; make -C vendor/jimtcl && make && gdb ./folk -ex=run'


flamegraph:
	sudo perf record -F 997 --pid=$(shell pgrep folk) -g -- sleep 30
	sudo perf script -f > out.perf
	~/FlameGraph/stackcollapse-perf.pl out.perf > out.folded
	~/FlameGraph/flamegraph.pl out.folded > out.svg

remote-flamegraph:
	ssh -t $(FOLK_REMOTE_NODE) -- make -C folk2 flamegraph
	scp $(FOLK_REMOTE_NODE):~/folk2/out.svg .
	scp $(FOLK_REMOTE_NODE):~/folk2/out.perf .
