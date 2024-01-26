workqueue: workqueue.c
	cc -o$@ -I./vendor/libpqueue/src vendor/libpqueue/src/pqueue.c workqueue.c

