ifeq ($(shell uname -s),Linux)
	override BUILTIN_CFLAGS += -Wl,--export-dynamic
endif

ifneq (,$(filter -DTRACY_ENABLE,$(CFLAGS)))
# Tracy is enabled
	TRACY_TARGET = vendor/tracy/public/TracyClient.o
	override CPPFLAGS += -std=c++20 -DTRACY_ENABLE
	LINKER := c++
else
	LINKER := cc
endif

folk: workqueue.o db.o trie.o sysmon.o epoch.o cache.o folk.o \
	vendor/c11-queues/mpmc_queue.o vendor/c11-queues/memory.o \
	vendor/jimtcl/libjim.a $(TRACY_TARGET) CFLAGS

	$(LINKER) -g -fno-omit-frame-pointer $(if $(ASAN_ENABLE),-fsanitize=address -fsanitize-recover=address,) -o$@ \
		$(CFLAGS) $(BUILTIN_CFLAGS) \
		-L./vendor/jimtcl \
		$(filter %.o %.a,$^) \
		-ljim -lm -lssl -lcrypto -lz
	if [ "$$(uname)" = "Darwin" ]; then \
		dsymutil $@; \
	fi
	# Hack for the gadget trigger button.
	if [ "$$(uname)" = "Linux" ]; then \
		sudo -n true 2>/dev/null || true && sudo setcap cap_sys_rawio+ep $@ || true; \
	fi

%.o: %.c trie.h CFLAGS
	cc -c -O2 -g -fno-omit-frame-pointer $(if $(ASAN_ENABLE),-fsanitize=address -fsanitize-recover=address,) -o$@  \
		-D_GNU_SOURCE $(CFLAGS) $(BUILTIN_CFLAGS) \
		$< -I./vendor/jimtcl -I./vendor/tracy/public

.PHONY: test clean deps
test: folk
	@count=1; \
	total=$$(ls test/*.folk | wc -l | tr -d ' '); \
	for test in test/*.folk; do \
		echo "Running test: $$test ($${count}/$$total)"; \
		echo "--------------------"; \
		./folk $$test; \
		result=$$?; \
		if [ $$result -eq 0 ]; then \
			echo "Ran test: $$test ($${count}/$$total): ✅ passed"; \
		else \
			echo "Ran test: $$test ($${count}/$$total): ❌ failed"; \
		fi; \
		echo ""; \
		count=$$((count + 1)); \
	done
test/%: test/%.folk folk
	./folk $<
debug-test/%: test/%.folk folk
	lldb -- ./folk $<

debug: folk
	if [ "$$(uname)" = "Darwin" ]; then \
		lldb -o "process handle -p true -s false SIGUSR1" -- ./folk; \
	else \
		gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop" ./folk; \
	fi

clean:
	rm -f folk *.o vendor/tracy/public/TracyClient.o vendor/c11-queues/*.o
distclean: clean
	make -C vendor/jimtcl distclean
	make -C vendor/apriltag clean

remote-clean: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make clean'
remote-distclean: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make distclean'
deps:
	if [ ! -f vendor/jimtcl/Makefile ]; then \
		cd vendor/jimtcl && ./configure CFLAGS='-g -fno-omit-frame-pointer' && cd -; \
	fi
	make -C vendor/jimtcl
	make -C vendor/apriltag libapriltag.so
	if [ "$$(uname)" = "Darwin" ]; then \
		install_name_tool -id @executable_path/vendor/apriltag/libapriltag.so vendor/apriltag/libapriltag.so; \
	fi

kill-folk:
	sudo systemctl stop folk
	if [ -f folk.pid ]; then \
		OLD_PID=`cat folk.pid`; \
		sudo pkill -9 --pgroup $$OLD_PID; \
		while sudo pkill -0 --pgroup $$OLD_PID; do sleep 0.2; done; \
	fi

FOLK_REMOTE_NODE ?= folk-live

sync:
	git ls-files --exclude-standard -oi --directory >.git/ignores.tmp
	rsync --timeout=15 -e "ssh -o StrictHostKeyChecking=no" \
		--archive --delete --itemize-changes \
		--exclude='/.git' \
		--exclude-from='.git/ignores.tmp' \
		./ $(FOLK_REMOTE_NODE):~/folk2/
remote-setup:
	ssh-copy-id $(FOLK_REMOTE_NODE)
	make sync
	ssh $(FOLK_REMOTE_NODE) -- 'sudo usermod -a -G tty folk && chmod +rwx ~/folk-calibration-poses; sudo apt update && sudo apt install libssl-dev gdb libwslay-dev google-perftools libgoogle-perftools-dev linux-perf && cd folk2/vendor/jimtcl && make distclean; ./configure CFLAGS="-g -fno-omit-frame-pointer"'

remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make start CFLAGS="$(CFLAGS)" ASAN_ENABLE=$(ASAN_ENABLE)'
sudo-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && sudo HOME=/home/folk TRACY_SAMPLING_HZ=31000 ./folk'
debug-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop" ./folk'
debug-sudo-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && sudo HOME=/home/folk TRACY_SAMPLING_HZ=31000 gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop"  ./folk'
valgrind-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make && valgrind --leak-check=yes ./folk'
heapprofile-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so HEAPPROFILE=/tmp/folk.hprof PERFTOOLS_VERBOSE=-1 ./folk'
debug-heapprofile-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so HEAPPROFILE=/tmp/folk.hprof PERFTOOLS_VERBOSE=-1 gdb -ex "handle SIGUSR1 nostop" ./folk'
heapprofile-remote-show:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; google-pprof --text folk $(HEAPPROFILE)'
heapprofile-remote-svg:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; google-pprof --svg folk $(HEAPPROFILE)' > out.svg

flamegraph:
	sudo perf record --freq=997 --call-graph lbr --pid=$(shell cat folk.pid) -g -- sleep 30
	sudo perf script -f > out.perf
	~/FlameGraph/stackcollapse-perf.pl out.perf > out.folded
	~/FlameGraph/flamegraph.pl out.folded > out.svg

remote-flamegraph:
	ssh -t $(FOLK_REMOTE_NODE) -- make -C folk flamegraph
	scp $(FOLK_REMOTE_NODE):~/folk/out.svg .
	scp $(FOLK_REMOTE_NODE):~/folk/out.perf .

start: folk
	@if [ -n "$$(systemctl list-unit-files | grep folk.service)" ] && \
	   [ -n "$$(systemctl cat folk.service | grep "ExecStart.*$$(pwd)")" ] && \
	   [ -z "$(ENABLE_ASAN)" ] && \
	   [ -z "$$INVOCATION_ID" ] && \
	   [ -z "$(CFLAGS)" ] ; then \
		sudo systemctl start folk.service; \
		journalctl -f -u folk.service; \
	else \
		$(if $(ENABLE_ASAN),ASAN_OPTIONS=detect_leaks=1:halt_on_error=0,) ./folk; \
	fi

run-tracy:
	vendor/tracy/profiler/build/tracy-profiler
tracy-remote:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk'
	vendor/tracy/profiler/build/tracy-profiler -a `ssh -G $(FOLK_REMOTE_NODE) | awk '$$1 == "hostname" { print $$2 }'` & \
		make remote CFLAGS=-DTRACY_ENABLE FOLK_REMOTE_NODE=$(FOLK_REMOTE_NODE)
sudo-tracy-remote:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; make kill-folk'
	vendor/tracy/profiler/build/tracy-profiler -a `ssh -G $(FOLK_REMOTE_NODE) | awk '$$1 == "hostname" { print $$2 }'` & \
		make sudo-remote CFLAGS=-DTRACY_ENABLE FOLK_REMOTE_NODE=$(FOLK_REMOTE_NODE)

# From https://stackoverflow.com/a/26147844 to force rebuild if CFLAGS
# changes (in particular, so we rebuild if we want to use Tracy)
define DEPENDABLE_VAR
.PHONY: phony
$1: phony
	@if [ "`cat $1 2>&1`" != '$($1)' ]; then \
		/bin/echo -n $($1) > $1 ; \
	fi
endef
$(eval $(call DEPENDABLE_VAR,CFLAGS))
