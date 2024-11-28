ifeq ($(shell uname -s),Linux)
	override CFLAGS += -Wl,--export-dynamic
endif
folk: workqueue.c db.c trie.c sysmon.c folk.c vendor/jimtcl/libjim.a
	cc -g -o$@ $(CFLAGS) \
		-I./vendor/jimtcl -L./vendor/jimtcl \
		workqueue.c db.c trie.c sysmon.c folk.c \
		-ljim -lm -lssl -lcrypto -lz

.PHONY: test clean
test: folk
	./folk test/test.folk
clean:
	rm -f folk

debug-attach:
	lldb --attach-name folk

FOLK_REMOTE_NODE := folk-live
sync:
	rsync --timeout=5 -e "ssh -o StrictHostKeyChecking=no" --archive \
		--include='**.gitignore' --exclude='/.git' --filter=':- .gitignore' \
		. $(FOLK_REMOTE_NODE):~/folk2 \
		--delete-after
setup-remote:
	ssh-copy-id $(FOLK_REMOTE_NODE)
	make sync
	ssh $(FOLK_REMOTE_NODE) -- 'sudo apt update && sudo apt install libssl-dev gdb libwslay-dev google-perftools libgoogle-perftools-dev linux-perf; cd folk2/vendor/jimtcl; ./configure CFLAGS=-g'

remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; sudo systemctl stop folk; killall -9 folk; make -C vendor/jimtcl && make -C vendor/apriltag libapriltag.so && make CFLAGS=$(CFLAGS) && ./folk'
debug-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; sudo systemctl stop folk; killall -9 folk; make -C vendor/jimtcl && make -C vendor/apriltag libapriltag.so && make CFLAGS=$(CFLAGS) && gdb ./folk -ex=run'
valgrind-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; sudo systemctl stop folk; killall -9 folk; ps aux | grep valgrind | grep -v bash | tr -s " " | cut -d " " -f 2 | xargs kill -9; make -C vendor/jimtcl && make && valgrind --leak-check=yes ./folk'
heapprofile-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; sudo systemctl stop folk; killall -9 folk; make -C vendor/jimtcl && make -C vendor/apriltag libapriltag.so && make CFLAGS=$(CFLAGS) && env LD_PRELOAD=libtcmalloc.so HEAPPROFILE=/tmp/folk.hprof PERFTOOLS_VERBOSE=-1 ./folk'
heapprofile-remote-show:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; google-pprof --text folk $(HEAPPROFILE)'
heapprofile-remote-svg:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; google-pprof --svg folk $(HEAPPROFILE)' > out.svg

flamegraph:
	sudo perf record -F 997 --call-graph dwarf --pid=$(shell pgrep folk) -g -- sleep 30
	sudo perf script -f > out.perf
	~/FlameGraph/stackcollapse-perf.pl out.perf > out.folded
	~/FlameGraph/flamegraph.pl out.folded > out.svg

remote-flamegraph:
	ssh -t $(FOLK_REMOTE_NODE) -- make -C folk2 flamegraph
	scp $(FOLK_REMOTE_NODE):~/folk2/out.svg .
	scp $(FOLK_REMOTE_NODE):~/folk2/out.perf .
