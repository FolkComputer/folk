ifeq ($(shell uname -s),Linux)
	CFLAGS := -Wl,--export-dynamic
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

FOLK_REMOTE_NODE := folk-convivial
remote:
	rsync --delete  --include "vendor/jimtcl/*.c" --exclude "vendor/jimtcl/*" --exclude folk --timeout=5 -e "ssh -o StrictHostKeyChecking=no" -a . $(FOLK_REMOTE_NODE):~/folk2
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; killall folk; make -C vendor/jimtcl && make && ./folk'
debug-remote:
	rsync --delete  --include "vendor/jimtcl/*.c" --exclude "vendor/jimtcl/*" --exclude folk --timeout=5 -e "ssh -o StrictHostKeyChecking=no" -a . $(FOLK_REMOTE_NODE):~/folk2
	ssh $(FOLK_REMOTE_NODE) -- 'cd folk2; killall folk; make -C vendor/jimtcl && make && gdb ./folk -ex=run'
