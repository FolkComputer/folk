# terminal.tcl --
#
#     Implements a virtual terminal with basic read/write procs.
#

set cc [c create]
$cc cflags -I./vendor/libtmt ./vendor/libtmt/tmt.c

# TODO: find the right libutil.so for the system
c loadlib /lib/aarch64-linux-gnu/libutil.so
$cc cflags -lutil

$cc include <sys/types.h>
$cc include <stdio.h>
$cc include <stdlib.h>
$cc include <unistd.h>
$cc include <pty.h>
$cc include <fcntl.h>
$cc include <string.h>
$cc include <sys/time.h> ;# For gettimeofday()
$cc include "tmt.h"

$cc struct VTerminal {
  TMT* tmt;
  int pty_fd;

  char* screen;
  int curs_r;
  int curs_c;
};

$cc code {
  #define SHELL "/bin/bash"
  #define ROWS 12
  #define COLS 43
  #define PTYBUF 4096
  char iobuf[PTYBUF];

  char* char_at(VTerminal *vt, int r, int c) {
    int i = r * (COLS + 1) + c;
    return &vt->screen[i];
  }

  void tmt_callback(tmt_msg_t m, TMT *tmt, const void *a, void *p) {
      VTerminal *vt = (VTerminal*)p;
      const TMTSCREEN *s = tmt_screen(tmt);

      if (m == TMT_MSG_UPDATE) {
        for (size_t r = 0; r < s->nline; r++){
            if (s->lines[r]->dirty){
                for (size_t c = 0; c < s->ncol; c++){
                  *char_at(vt, r, c) = s->lines[r]->chars[c].c;
                }
            }
        }
        tmt_clean(tmt);
      }
  }

  void updateCursor(VTerminal *vt) {
    // Restore char under old cursor
    const TMTSCREEN *s = tmt_screen(vt->tmt);
    *char_at(vt, vt->curs_r, vt->curs_c) = s->lines[vt->curs_r]->chars[vt->curs_c].c;

    // Update new cursor
    const TMTPOINT *c = tmt_cursor(vt->tmt);
    vt->curs_r = c->r;
    vt->curs_c = c->c;

    // Replace char with cursor every other second
    struct timeval tv;
    gettimeofday(&tv, NULL);
    if (tv.tv_sec % 2 == 0) {
      *char_at(vt, vt->curs_r, vt->curs_c) = 0xDB; // block char: █
    }
  }
}

$cc proc termCreate {} VTerminal* {
  VTerminal *vt = malloc(sizeof(VTerminal));
  vt->curs_r = 0;
  vt->curs_c = 0;

  vt->screen = malloc(sizeof(char[ROWS][COLS + 1]));
  for (int r = 0; r < ROWS - 1; r++) *char_at(vt, r, COLS) = '\n';
  *char_at(vt, ROWS - 1, COLS) = '\0';

  vt->tmt = tmt_open(ROWS, COLS, tmt_callback, vt, NULL);

  struct winsize ws = {.ws_row = ROWS, .ws_col = COLS};
  pid_t pid = forkpty(&vt->pty_fd, NULL, NULL, &ws);
  if (pid < 0){
    return NULL;
  } else if (pid == 0){
    setenv("TERM", "ansi", 1);
    execl(SHELL, SHELL, NULL);
    return NULL;
  }

  fcntl(vt->pty_fd, F_SETFL, O_NONBLOCK);
  return vt;
}

$cc proc termDestory {VTerminal* vt} void {
  // TODO...
}

$cc proc termRead {VTerminal* vt} char* {
  ssize_t r = read(vt->pty_fd, iobuf, PTYBUF);
  if (r > 0) {
    tmt_write(vt->tmt, iobuf, r);
  }

  updateCursor(vt);
  return vt->screen;
}

$cc proc termWrite {VTerminal* vt char* key} void {
  write(vt->pty_fd, key, strlen(key));
}

$cc compile

# Folk stuff...

namespace eval Terminal {
  # From `man console_codes`
  variable keymap [dict create \
    ENTER     "\x0d" \
    TAB       "\x09" \
    BACKSPACE "\x08" \
    DELETE    "\x7f" \
    ESC       "\x1b" \
    UP        "\x1b\[A" \
    DOWN      "\x1b\[B" \
    RIGHT     "\x1b\[C" \
    LEFT      "\x1b\[D" \
  ]

  proc remap {key ctrlPressed} {
    variable keymap
    if {[string length $key] == 1} {
      # Convert ctrl-A through ctrl-Z and others to terminal control characters
      if {$ctrlPressed} {
        set charCode [scan [string toupper $key] %c]
        if {$charCode >= 64 && $charCode <= 95} {
          set charCode [expr {$charCode - 64}]
          return [format %c $charCode]
        }
      }
      # All other single char keys can be passed through
      return $key
    }
    if {[dict exists $keymap $key]} {
      return [dict get $keymap $key]
    }
    return ""
  }

  # Creates a new virtual terminal and returns its ID
  proc create {} {
    return [termCreate]
  }

  proc destroy {term} {
    termDestroy $term
  }

  # Writes a keyboard key to the terminal, handling control codes
  proc write {term key ctrlPressed} {
    set key [remap $key $ctrlPressed]
    if {[string length $key] > 0} {
      termWrite $term $key
    }
  }

  # Returns a newline separated string of terminal lines
  proc read {term} {
    return [termRead $term]
  }
}
