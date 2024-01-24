#include <stdio.h>
#include <stdlib.h>
#include <ctype.h>
#include "shm_malloc.h"

struct list {
    struct list	*next;
};

#define MAX_PATTERNS	100
struct pattern {
    long		size, count;
} test[MAX_PATTERNS];
int patterns=0;

long getval(char *s, char **p)
{
    long rv = strtol(s, p, 0);
    char ch = **p;
    if (ch == 'k' || ch == 'K') {
	rv *= 1024;
	++*p;
    } else if (ch == 'm' || ch == 'M') {
	rv *= 1024*1024;
	++*p;
    } else if (ch == 'g' || ch == 'G') {
	rv *= 1024*1024*1024;
	++*p;
    }
    return rv;
}

int main(int ac, char **av)
{
    int	i, j;
    struct list *head = 0, **tail = &head, *l, *next;
    const char *file = 0;
    long total = 0, maxcnt = 0, count;
    int suffix;

    for (i = 1; i < ac; i++) {
	if (isdigit(*av[i]) && patterns < MAX_PATTERNS) {
	    char *p;
	    long v = getval(av[i], &p);
	    if (*p == 'x' || *p == 'X') {
		test[patterns].count = v;
		test[patterns].size = getval(p+1, &p);
	    } else {
		test[patterns].count = 1;
		test[patterns].size = v;
	    }
	    if (*p) {
		fprintf(stderr, "ignoring bad pattern: %s\n", av[i]);
	    } else {
		if (test[patterns].count > maxcnt)
		    maxcnt = test[patterns].count;
		total += test[patterns].count * test[patterns].size ;
		patterns++;
	    }
	} else if (!file) {
	    file = av[i];
	} else {
	    patterns = 0;
	    break;
	}
    }
    if (patterns == 0) {
	fprintf(stderr, "usage: %s [file] pattern...\n", av[0]);
	exit(1);
    }
    if (shm_init(file) < 0) {
	perror("shm_init");
	exit(1); }
    suffix = 0;
    while (total > 2000 && suffix < 4) {
	suffix++;
	total = (total+512)/1024; }
    printf("Attempting %d patterns for %ld%c total\n",
	   patterns, total, " KMGT"[suffix]);
    total = 0;
    for (i = 0; i < maxcnt; i++)
	for (j = 0; j < patterns; j++)
	    if (i < test[j].count) {
		*tail = shm_malloc(test[j].size);
		if (*tail) {
		    total += test[j].size;
		    tail = &(*tail)->next;
		} else {
		    suffix = 0;
		    while (total > 2000 && suffix < 4) {
			suffix++;
			total = (total+512)/1024; }
		    printf("Alloc failed after %ld%c\n",
			   total, " KMGT"[suffix]);
		    i = maxcnt;
		    break; } }
    *tail = 0;
    printf("Done with allocation, now freeing\n");
    count = 0;
    for (l = head; l; l = next) {
	next = l->next;
	if (next) {
	    l->next = next->next;
	    shm_free(next);
	    if (++count == 1000) {
		putchar('.'); fflush(stdout);
		count = 0; }
	    next = l->next; } }
    printf("\nFreed half, now freeing remainder\n");
    count = 0;
    for (l = head; l; l = next) {
	next = l->next;
	shm_free(l);
	if (++count == 1000) {
	    putchar('.'); fflush(stdout);
	    count = 0; } }
    printf("\n");
    return 0;
}
