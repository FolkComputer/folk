CFLAGS ?= -O2 -Wall -Wextra -Wno-unused-parameter -Wno-format-truncation
all: hidemu
# name <-> code table straight from the kernel uapi header, so nothing is copied by hand
keynames.h: /usr/include/linux/input-event-codes.h
	awk 'BEGIN{print "static const struct { const char* name; int code; } keynames[] = {"} \
	     /^#define (KEY|BTN)_[A-Z0-9_]+[ \t]/ && $$2!="KEY_MAX" && $$2!="KEY_CNT" && $$2!="KEY_MIN_INTERESTING" && $$2!="KEY_RESERVED" {printf "    {\"%s\", %s},\n", $$2, $$2} \
	     END{print "};"}' $< > $@
hidemu: hidemu.c keynames.h
	$(CC) $(CFLAGS) -o $@ hidemu.c
clean:
	rm -f hidemu keynames.h
