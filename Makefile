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
