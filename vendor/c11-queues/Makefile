TARGETS = spsc_ub_test_fib spsc_ub_test_default mpmc_test mpmc_test_fib spsc_test_fib
CFLAGS = -Wall -std=c11
ifeq ($(shell uname), Linux)
	LIBS = -pthread
endif

DEBUG ?= 1

ifdef DEBUG
	CFLAGS += -g -O0
else
	CFLAGS += -O3
endif

.PHONY: all clean

all: $(TARGETS)

spsc_ub_test_fib: spsc_ub_test_fib.o spsc_ub_queue.o memory.o
	$(CC) $^ -Wall $(LIBS) -o $@

spsc_ub_test_default: spsc_ub_test_default.o spsc_ub_queue.o memory.o
	$(CC) $^ -Wall $(LIBS) -o $@

mpmc_test: mpmc_test.o mpmc_queue.o memory.o
	$(CC) $^ -Wall $(LIBS) -o $@
	
mpmc_test_fib: mpmc_test_fib.o mpmc_queue.o memory.o
	$(CC) $^ -Wall $(LIBS) -o $@

spsc_test_fib: spsc_test_fib.o spsc_queue.o memory.o
	$(CC) $^ -Wall $(LIBS) -o $@

%.o: %.c
	$(CC) $(CFLAGS) -c $< -o $@

clean:
	rm -f *.o
	rm -f $(TARGETS)
