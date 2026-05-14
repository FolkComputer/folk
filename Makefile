# This Makefile should only be for stuff that is part of the absolute
# core interpreter of Folk (Tcl, workqueue, trie/db, scheduler) and/or
# stuff that absolutely needs to be global and active from process
# start and should seep into everything (output redirection, Linux
# capability, Tracy, block stats).
#
# Intuition: if something can live in 'userspace' (e.g., graphics,
# webcam, Web server, geometry), it should not be here and should be
# managed from userspace Folk program(s). You should think very hard
# before adding new dependencies to this Makefile.

ifeq ($(shell uname -s),Linux)
	override BUILTIN_CFLAGS += -Wl,--export-dynamic
else
	# folk_interpose.dylib holds the __interpose section for write() redirection.
	# (dyld only processes __interpose from dylibs, not from the main executable.)
	INTERPOSE_DYLIB = folk_interpose.dylib
	INTERPOSE_LDFLAGS = -Wl,-rpath,@executable_path ./folk_interpose.dylib
endif

ifneq (,$(filter -DTRACY_ENABLE,$(CFLAGS)))
# Tracy is enabled
	TRACY_TARGET = vendor/tracy/public/TracyClient.o
	override CPPFLAGS += -std=c++20 -DTRACY_ENABLE
	LINKER := c++
else
	LINKER := cc
endif

folk: workqueue.o db.o trie.o sysmon.o epoch.o folk.o output-redirection.o block-stats.o \
	vendor/c11-queues/mpmc_queue.o vendor/c11-queues/memory.o \
	vendor/jimtcl/libjim.a $(TRACY_TARGET) CFLAGS $(INTERPOSE_DYLIB)

	$(LINKER) -g -fno-omit-frame-pointer $(if $(ASAN_ENABLE),-fsanitize=address -fsanitize-recover=address,) -o$@ \
		$(CFLAGS) $(BUILTIN_CFLAGS) \
		-L./vendor/jimtcl \
		$(filter %.o %.a,$^) \
		-ljim -lm -lssl -lcrypto -lz $(INTERPOSE_LDFLAGS)
	if [ "$$(uname)" = "Darwin" ]; then \
		dsymutil $@; \
	fi
	# Hack for the gadget trigger button.
	if [ "$$(uname)" = "Linux" ]; then \
		(sudo -n true 2>/dev/null && sudo setcap cap_sys_rawio+ep $@) || true; \
	fi

%.o: %.c trie.h workqueue.h CFLAGS
	cc -c -O2 -g -fno-omit-frame-pointer $(if $(ASAN_ENABLE),-fsanitize=address -fsanitize-recover=address,) -o$@  \
		-D_GNU_SOURCE -U_FORTIFY_SOURCE $(CFLAGS) $(BUILTIN_CFLAGS) \
		$< -I./vendor/jimtcl -I./vendor/tracy/public

folk_interpose.dylib: output-redirection.c
	cc -dynamiclib -undefined dynamic_lookup \
		-install_name @executable_path/folk_interpose.dylib \
		-O2 -g -fno-omit-frame-pointer \
		-DFOLK_INTERPOSE_DYLIB \
		-o $@ $<

.PHONY: test clean deps macos-bundle kill-folk
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
	if [ "$$(uname)" = "Darwin" ]; then \
		lldb -o "process handle -p true -s false SIGUSR1" -- ./folk $<; \
	else \
		gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop" --args ./folk $<; \
	fi

debug: folk
	if [ "$$(uname)" = "Darwin" ]; then \
		lldb -o "process handle -p true -s false SIGUSR1" -- ./folk; \
	else \
		gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop" ./folk; \
	fi

clean:
	rm -f folk *.o *.dylib vendor/tracy/public/TracyClient.o vendor/c11-queues/*.o
distclean: clean
	make -C vendor/jimtcl distclean

remote-clean: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make clean'
remote-distclean: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make distclean'
deps:
	if [ ! -f vendor/jimtcl/Makefile ]; then \
		cd vendor/jimtcl && ./configure CFLAGS='-g -fno-omit-frame-pointer'; \
	fi
	make -C vendor/jimtcl

macos-bundle: folk
	@if [ "$$(uname -s)" != "Darwin" ]; then \
		echo "macos-bundle can only be built on Darwin"; \
		exit 1; \
	fi
	rm -rf build/Folk.app
	mkdir -p build/Folk.app/Contents/MacOS
	mkdir -p build/Folk.app/Contents/Resources/folk-root
	mkdir -p build/Folk.app/Contents/Resources/folk-root/builtin-programs
	mkdir -p build/Folk.app/Contents/Resources/folk-root/lib
	mkdir -p build/Folk.app/Contents/Resources/folk-root/vendor
	mkdir -p build/Folk.app/Contents/Resources/folk-root/assets
	mkdir -p build/Folk.app/Contents/Resources/folk-root/user-programs
	cp folk build/Folk.app/Contents/MacOS/folk
	cp folk_interpose.dylib build/Folk.app/Contents/MacOS/folk_interpose.dylib
	cp boot.folk prelude.tcl build/Folk.app/Contents/Resources/folk-root/
	cp *.h build/Folk.app/Contents/Resources/folk-root/
	rsync -a --delete builtin-programs/ build/Folk.app/Contents/Resources/folk-root/builtin-programs/
	rsync -a --delete lib/ build/Folk.app/Contents/Resources/folk-root/lib/
	rsync -a --delete assets/ build/Folk.app/Contents/Resources/folk-root/assets/
	rsync -a --delete --exclude='tracy/.git' vendor/ build/Folk.app/Contents/Resources/folk-root/vendor/
	{ \
		printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?>'; \
		printf '%s\n' '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"'; \
		printf '%s\n' ' "http://www.apple.com/DTDs/PropertyList-1.0.dtd">'; \
		printf '%s\n' '<plist version="1.0">'; \
		printf '%s\n' '  <dict>'; \
		printf '%s\n' '    <key>CFBundleExecutable</key>'; \
		printf '%s\n' '    <string>folk</string>'; \
		printf '%s\n' '    <key>CFBundleIdentifier</key>'; \
		printf '%s\n' '    <string>computer.folk.local</string>'; \
		printf '%s\n' '    <key>CFBundleName</key>'; \
		printf '%s\n' '    <string>Folk</string>'; \
		printf '%s\n' '    <key>CFBundlePackageType</key>'; \
		printf '%s\n' '    <string>APPL</string>'; \
		printf '%s\n' '    <key>CFBundleVersion</key>'; \
		printf '%s\n' '    <string>0.1</string>'; \
		printf '%s\n' '    <key>CFBundleShortVersionString</key>'; \
		printf '%s\n' '    <string>0.1</string>'; \
		printf '%s\n' '    <key>NSCameraUsageDescription</key>'; \
		printf '%s\n' '    <string>Folk needs camera access to publish local camera frames.</string>'; \
		printf '%s\n' '  </dict>'; \
		printf '%s\n' '</plist>'; \
	} > build/Folk.app/Contents/Info.plist
	codesign --force --deep --sign - build/Folk.app


kill-folk:
	@if [ "$$(uname -s)" = "Darwin" ]; then \
		APP_EXEC="$$(pwd)/build/Folk.app/Contents/MacOS/folk"; \
		LOCAL_EXEC="$$(pwd)/folk"; \
		kill_pid() { \
			OLD_PID="$$1"; \
			if [ -z "$$OLD_PID" ] || ! kill -0 "$$OLD_PID" 2>/dev/null; then return 0; fi; \
			CMD="$$(ps -p "$$OLD_PID" -o command= 2>/dev/null || true)"; \
			case "$$CMD" in \
				*"$$APP_EXEC"*|*"$$LOCAL_EXEC"*) ;; \
				*) echo "Skipping PID $$OLD_PID ($$CMD)"; return 1 ;; \
			esac; \
			PGID="$$(ps -o pgid= -p "$$OLD_PID" 2>/dev/null | tr -d ' ' || true)"; \
			echo "Stopping Folk PID $$OLD_PID"; \
			if [ -n "$$PGID" ]; then kill -TERM -$$PGID 2>/dev/null || true; fi; \
			kill -TERM "$$OLD_PID" 2>/dev/null || true; \
			WAIT=0; \
			while kill -0 "$$OLD_PID" 2>/dev/null && [ "$$WAIT" -lt 50 ]; do sleep 0.1; WAIT=$$((WAIT + 1)); done; \
			if kill -0 "$$OLD_PID" 2>/dev/null; then \
				if [ -n "$$PGID" ]; then kill -KILL -$$PGID 2>/dev/null || true; fi; \
				kill -KILL "$$OLD_PID" 2>/dev/null || true; \
			fi; \
		}; \
		for PID_FILE in "folk.pid" "$$HOME/Library/Application Support/Folk/folk.pid"; do \
			if [ -f "$$PID_FILE" ]; then \
				OLD_PID="$$(cat "$$PID_FILE" 2>/dev/null || true)"; \
				if kill_pid "$$OLD_PID"; then \
					rm -f "$$PID_FILE"; \
				fi; \
			fi; \
		done; \
		for OLD_PID in $$(pgrep -f "$$APP_EXEC" 2>/dev/null || true); do \
			kill_pid "$$OLD_PID"; \
		done; \
	else \
		sudo systemctl stop folk; \
		if [ -f folk.pid ]; then \
			OLD_PID=`cat folk.pid`; \
			pkill -9 --pgroup $$OLD_PID; \
			sudo pkill -9 --pgroup $$OLD_PID; \
			while sudo pkill -0 --pgroup $$OLD_PID; do sleep 0.2; done; \
		fi; \
	fi

FOLK_REMOTE_NODE ?= folk-live

sync:
	ssh $(FOLK_REMOTE_NODE) -t \
		'cd ~/folk && git init > /dev/null && git ls-files --exclude-standard -oi --directory' \
		> .git/ignores.tmp || true
	git ls-files --exclude-standard -oi --directory >> .git/ignores.tmp
	rsync --timeout=15 -e "ssh -o StrictHostKeyChecking=no" \
		--archive --delete --itemize-changes \
		--exclude='/.git' \
		--exclude-from='.git/ignores.tmp' \
		--exclude='vendor/tracy/public/TracyClient.o' \
		--include='vendor/tracy/public/***' \
		--exclude='vendor/tracy/*' \
		./ $(FOLK_REMOTE_NODE):~/folk/

remote-setup:
	ssh-copy-id $(FOLK_REMOTE_NODE)
	make sync
	ssh $(FOLK_REMOTE_NODE) -- 'sudo usermod -a -G tty folk && chmod +rwx ~/folk-calibration-poses; sudo apt update && sudo apt install libssl-dev gdb libwslay-dev google-perftools libgoogle-perftools-dev linux-perf && cd folk/vendor/jimtcl && make distclean; ./configure CFLAGS="-g -fno-omit-frame-pointer"'

remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make start CFLAGS="$(CFLAGS)" ASAN_ENABLE=$(ASAN_ENABLE)'
sudo-remote: sync
	ssh -tt $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && sudo HOME=/home/folk TRACY_SAMPLING_HZ=999 ./folk'
debug-remote: sync
	ssh -tt $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop" ./folk'
debug-sudo-remote: sync
	ssh -tt $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && sudo HOME=/home/folk TRACY_SAMPLING_HZ=999 gdb -ex "handle SIGUSR1 nostop" -ex "handle SIGPIPE nostop"  ./folk'
valgrind-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make && valgrind --leak-check=yes ./folk'
heapprofile-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so HEAPPROFILE=/tmp/folk.hprof PERFTOOLS_VERBOSE=-1 ./folk'
debug-heapprofile-remote: sync
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk; make deps && make CFLAGS="$(CFLAGS)" && env LD_PRELOAD=/usr/lib/x86_64-linux-gnu/libtcmalloc.so HEAPPROFILE=/tmp/folk.hprof PERFTOOLS_VERBOSE=-1 gdb -ex "handle SIGUSR1 nostop" ./folk'
heapprofile-remote-show:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; google-pprof --text folk $(HEAPPROFILE)'
heapprofile-remote-svg:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; google-pprof --svg folk $(HEAPPROFILE)' > out.svg

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
		journalctl --output=cat -f -u folk.service; \
	else \
		$(if $(ENABLE_ASAN),ASAN_OPTIONS=detect_leaks=1:halt_on_error=0,) ./folk; \
	fi

run-tracy:
	vendor/tracy/profiler/build/tracy-profiler
tracy-remote:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk'
	vendor/tracy/profiler/build/tracy-profiler -a `ssh -G $(FOLK_REMOTE_NODE) | awk '$$1 == "hostname" { print $$2 }'` & \
		make remote CFLAGS=-DTRACY_ENABLE FOLK_REMOTE_NODE=$(FOLK_REMOTE_NODE)
sudo-tracy-remote:
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk; make kill-folk'
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
