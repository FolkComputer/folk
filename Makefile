main: workqueue.c db.c trie.c main.c vendor/jimtcl/libjim.a
	cc -g -o$@ \
		-I./vendor/libpqueue/src vendor/libpqueue/src/pqueue.c \
		-I./vendor/jimtcl -L./vendor/jimtcl -ljim -lssl -lcrypto -lz \
		workqueue.c db.c trie.c main.c

