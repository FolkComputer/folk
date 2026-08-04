# Speculative API design: `has new messages`

Target: make this program (or something very close to it) work on a
Folk table:

```tcl
When folkcomputer@icloud.com has new messages /m/ {
    Wish $this is labelled with $m
}
```

i.e., put a page on the table and it shows you your new mail; take it
off (or read the mail) and the label goes away.

The working form this proposal lands on differs from the target in
one word — the label wish takes text, not a dict (see the `is
labelled with` wrinkle below):

```tcl
When folkcomputer@icloud.com has new messages /m/ {
    Wish $this is labelled "[dict get $m from]:\n[dict get $m subject]"
}
```

This document works out what that snippet should *mean*, what
statement vocabulary a mail provider should emit so that the snippet
works with **zero changes to the language core**, and sketches the
provider itself.

## The core question: "new" is an edge, statements are levels

Folk statements are facts that *hold*: a `When` body runs while a
matching statement exists and everything downstream is retracted when
it stops existing. "A new message arrived" is an edge-triggered event,
not a level. So the first design decision is: what level does
`has new messages` denote? Three candidates:

### Option A — "new" means *unread* (recommended)

The provider claims one statement per currently-unseen message
(IMAP `UNSEEN`). The claim exists while the message is unread and is
retracted when the message gets read (or deleted) from any client —
phone, laptop, or a Folk program wishing it read.

This is the recommended semantics because it is self-cleaning and
matches how everything else in Folk works: it is exactly analogous to
`When tag 5 is on the table` — the fact appears, downstream wishes
(labels, sounds, prints) materialize; the fact disappears, they
unwind via the normal destructor mechanism. No program ever has to
remember what it has already reacted to.

### Option B — TTL pulses (`-keep`)

Like camera frames and `fswatch.folk`: on arrival, `Hold!` a claim
with `-keep 30000ms` so it exists for a window and then evaporates.
This is the right shape for "chime when mail arrives" behaviors, but
wrong as the *primary* API: a page placed on the table 31 seconds
after the mail arrived would show nothing, and the label vanishes
even though the mail is still unread. Providers can offer this as a
secondary vocabulary (see "recent" below) rather than the default.

### Option C — watermark ("new since this observer appeared")

"New" relative to when the `When` was asserted. Rejected: it requires
per-observer state, and Folk's database is global — statements don't
know who is watching them. Nothing else in the system works this way.

## Statement vocabulary

The beauty of Folk is that this API needs no new language machinery:
`When` already matches any statement shape word-by-word, so the API
design is really a *statement vocabulary* design. The provider emits,
for each unseen message:

```tcl
Claim folkcomputer@icloud.com has new messages $m
```

and the user's snippet matches once per message — `/m/` binds each
message in turn, and the body runs (and the label renders) once per
match, which is standard Folk multi-match behavior.

Grammatical note: `has new messages /m/` binding *one* message per
match reads slightly oddly. Two ways to resolve it:

1. **Accept it** (recommended for the target snippet). Folk statements
   are natural-language-*ish*; nothing parses their grammar. Matching
   a plural collective predicate once per item has precedent in how
   people actually write patterns.
2. Offer the honest singular/plural pair alongside it:

   ```tcl
   When folkcomputer@icloud.com has new message /m/ { ... }           ;# per message
   When the collected results for [list folkcomputer@icloud.com \
       has new message /m/] are /ms/ { ... }                          ;# all at once
   ```

   The collected form is the one to use for "3 new messages" badge
   counts, via the existing `the collected results for` machinery
   (same trick `decorations/label.folk` uses).

### What is `$m`?

A Tcl dict. Suggested keys:

| key       | example                              |
|-----------|--------------------------------------|
| `uid`     | IMAP UID, stable per mailbox         |
| `from`    | `"Ada Lovelace <ada@example.com>"`   |
| `subject` | `"Analytical engine notes"`          |
| `date`    | seconds since epoch                  |
| `snippet` | first ~200 chars of the body, plain  |

Deliberately *not* included: the full body and attachments. Those are
large, and statements get copied around the dependency graph; fetch
them on demand instead (see "wishes back at the provider").

### A wrinkle in the target snippet: `is labelled with`

Today's label vocabulary (`builtin-programs/decorations/label.folk`)
is:

```
/someone/ wishes /thing/ is labelled /text/ with /...options/
```

so `Wish $this is labelled with $m` puts the literal word `with` in
the `/text/` slot and `$m` in the options slot — it won't render.

Fix (KISS): don't touch the label vocabulary at all. Drop the `with`
and format the dict with the tools Tcl already has:

```tcl
When folkcomputer@icloud.com has new messages /m/ {
    Wish $this is labelled "[dict get $m from]:\n[dict get $m subject]"
}
```

This is the working form of the target snippet: one existing
vocabulary, no sugar page, no new matching rules. Anything fancier
(a `labelled with <dict>` sugar statement) can be added later if the
phrasing turns out to matter, but the default is: labels take text,
so give them text.

## The provider: `mail.folk`

An ordinary program, not a kernel feature — same pattern as
`user-programs/haippi7/spotify.folk` (poll an HTTP API, assert claims)
and `builtin-programs/fswatch.folk` (blocking watcher loop feeding
`Hold!`). Sketch:

```tcl
# mail.folk — polls IMAP, mirrors the unseen set into the statement db.
set account "folkcomputer@icloud.com"
# iCloud: imap.mail.me.com:993, app-specific password.
# Credentials from env, like SPOTIFY_CLIENT_ID/SECRET:
#   FOLK_MAIL_USER, FOLK_MAIL_PASSWORD

proc ::pollMail {account} {
    set unseen [imap::fetchUnseen $account]   ;# list of dicts, uid keyed

    foreach m $unseen {
        # One held statement per message, keyed by uid: re-asserting
        # the same uid replaces in place (no flicker), and uids that
        # stop appearing are retracted below.
        Hold! -on mail.folk -key [list $account new [dict get $m uid]] \
            Claim $account has new messages $m
    }
    # Retract messages that are no longer unseen:
    foreach uid [dict keys $::mailPreviouslyUnseen] {
        if {$uid ni [lmap m $unseen {dict get $m uid}]} {
            Hold! -on mail.folk -key [list $account new $uid] {}
        }
    }
    set ::mailPreviouslyUnseen [lmap m $unseen {dict get $m uid}]

    after 30000 [list ::pollMail $account]
}
::pollMail $account
```

Key mechanics, all existing:

- `Hold!` with a per-uid `-key` gives replace/retract-by-key
  semantics, exactly how `camera/usb.folk` replaces frames and
  `sysmon.c` replaces `the clock time is`.
- Holding an empty clause (`{}`) on a key retracts it — the idiom
  `calibrate.folk` already uses.
- The poll loop lives on the provider program's thread; nothing
  blocks the reactive scheduler.

Provider status should also be a claim, so tables can debug at a
glance:

```tcl
Claim mail.folk is connected to $account          ;# or:
Claim mail.folk failed to connect to $account with error $err
```

### Wishes back at the provider

Symmetric with `spotify.folk`'s
`When /someone/ wishes /uri/ would be played on spotify`, the provider
listens for wishes so programs can act on mail, not just observe it:

```tcl
When /someone/ wishes $account marks /uid/ as read {
    imap::store $account $uid +FLAGS \\Seen
    # next poll retracts the "has new messages" claim; the label
    # disappears through the normal statement lifecycle.
}

When /someone/ wishes $account fetches the body of /uid/ {
    Claim $account has message body of $uid as [imap::fetchBody $account $uid]
}
```

Note the pleasing loop in the first one: wishing a message read causes
the *fact of its newness* to be retracted, which unwinds every label
and behavior that depended on it — no cleanup code anywhere.

### Secondary vocabulary: recent arrivals (Option B, opt-in)

For edge-flavored reactions (chime, flash, print-on-arrival):

```tcl
Hold! -keep 10000ms -on mail.folk -key [list $account arrived $uid] \
    Claim $account just received message $m
```

`just received` for edges, `has new` for levels; programs pick the
semantics they mean by picking the phrase.

## Configuration and multiple accounts

The account address is just the statement subject, so multiple
accounts come for free — run two provider instances (or one with a
list) and patterns naturally scope by address. A wildcard subscribes
to all of them:

```tcl
When /account/ has new messages /m/ { ... }
```

Credentials via env vars to start (the `spotify.folk` precedent);
a nicer future is an *account page* — a printed page that, while on
the table, claims the account should be connected, with a small web
setup flow (again like spotify's port-8888 flow) for entering the
app-specific password.

## Open questions

- **Privacy.** The statement database is global: once mail claims
  exist, *any* page on the table can read them. That is arguably the
  Folk ethos (the table is a shared physical space; a page you can
  see is a page you can read), but snippets-in-statements means mail
  content also flows into logs and the web editor. May want a
  provider option for headers-only claims.
- **Scale.** An inbox with 4,000 unread messages would mint 4,000
  statements and run matching bodies 4,000 times. The provider should
  cap the mirrored set (e.g. 50 most recent unseen) and claim
  `$account has /n/ more new messages` for the remainder.
- **Push vs poll.** IMAP IDLE would replace the 30 s poll with real
  push; the vocabulary above doesn't change, only the provider's
  inner loop.
- **Generalization.** Nothing here is mail-specific:
  `When /feed/ has new items /x/` with a per-item `Hold!` key and a
  read/ack wish is the same design for RSS, calendar invites, chat
  mentions, or webhooks. If a second provider appears, it may be
  worth extracting the `Hold-per-key, retract-on-disappear` mirror
  loop into a small library (`lib/feed.tcl`).
