main: main.c workqueue.c
	cc -g -o$@ -I./vendor/libpqueue/src vendor/libpqueue/src/pqueue.c workqueue.c db.c trie.c main.c

