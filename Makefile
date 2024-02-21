ifeq ($(shell uname -s),Linux)
	CFLAGS := -Wl,--export-dynamic
endif
main: workqueue.c db.c trie.c main.c vendor/jimtcl/libjim.a
	cc -g -o$@ $(CFLAGS) \
		-I./vendor/libpqueue/src vendor/libpqueue/src/pqueue.c \
		-I./vendor/jimtcl -L./vendor/jimtcl \
		workqueue.c db.c trie.c main.c \
		-ljim -lm -lssl -lcrypto -lz
