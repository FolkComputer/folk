
# The following uses gcc with optimizing and debugging symbols
CC = gcc
CFLAGS = -ggdb -O3 -Wall

MAKELIB = rm -f $@; ar qv $@ $^; ranlib $@

SRCS = malloc.c malloc.h atomic.h tshm1.c tshm2.c Makefile malloc.doc shm_malloc.h
MOBJS = malloc.o
SHMOBJS = shm_malloc.o
DBOBJS = db_malloc.o
DBSHMOBJS = db_shm_malloc.o

all: libmalloc.a libshm.a libdbmalloc.a libdbshm.a tshm1 tshm1db tanon tshm2 tshm2db

tshm1: tshm1.c $(SHMOBJS)
	$(CC) $(CFLAGS) -o $@ $^

tshm1db: tshm1.c $(DBSHMOBJS)
	$(CC) $(CFLAGS) -DSHM_FILE='"tshm1db_file"' -o $@ $^

tanon: tshm1.c $(SHMOBJS)
	$(CC) $(CFLAGS) -DSHM_FILE=0 -o $@ $^

tshm2: tshm2.c $(SHMOBJS)
	$(CC) $(CFLAGS) -o $@ $^

tshm2db: tshm2.c $(DBSHMOBJS)
	$(CC) $(CFLAGS) -o $@ $^

libmalloc.a: $(MOBJS); $(MAKELIB)
libshm.a: $(SHMOBJS); $(MAKELIB)
libdbmalloc.a: $(DBOBJS); $(MAKELIB)
libdbshm.a: $(DBSHMOBJS); $(MAKELIB)

malloc.o: malloc.h

shm_malloc.o: malloc.c malloc.h
	$(CC) -c $(CFLAGS) -DSHM malloc.c -o $@

db_malloc.o: malloc.c malloc.h
	$(CC) -c $(CFLAGS) -DMALLOC_DEBUG malloc.c -o $@

db_shm_malloc.o: malloc.c malloc.h
	$(CC) -c $(CFLAGS) -DMALLOC_DEBUG -DSHM malloc.c -o $@

tar: $(SRCS)
	-rm -f malloc.tar malloc.tar.gz
	tar cvf malloc.tar $(SRCS)
	gzip -9 malloc.tar

clean:
	-rm *.o *.a tshm1 tshm1db tshm2 tshm2db tanon

