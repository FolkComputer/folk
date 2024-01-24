#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "shm_malloc.h"

#ifndef SHM_FILE
#define SHM_FILE	"tshm1_file"
#endif

struct list {
    struct list	*next;
    char	*data;
};

struct head {
    struct list	*head;
    struct list	**tail;
};

void setup()
{
    struct head *h = shm_malloc(sizeof(struct head));
    if (!h) {
	perror("shm_malloc");
	exit(1); }
    h->head = 0;
    h->tail = &h->head;
    shm_set_global(h);
}

int main(int ac, char **av)
{
    int	i;
    struct head *h;
    struct list *l;

    if (shm_init(SHM_FILE, setup) < 0) {
	perror("shm_init");
	exit(1); }
    h = shm_global();
    if (!h) {
	perror("shm_global");
	exit(1); }
    for (i = 1; i < ac; i++) {
	if (!(l = shm_malloc(sizeof(struct list)))) {
	    perror("shm_malloc");
	    exit(1); }
	l->next = 0;
	if (!(l->data = shm_malloc(strlen(av[i]) + 1))) {
	    perror("shm_malloc");
	    exit(1); }
	strcpy(l->data, av[i]);
	*h->tail = l;
	h->tail = &l->next; }
    for (l = h->head; l; l = l->next) {
	printf("%s\n", l->data); }
    return 0;
}
