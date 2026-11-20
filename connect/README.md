# Folk Connect

A Web page (meant to live at one well-known HTTPS address) that finds
the Folk machines on your network and talks to them: run a program on
the table, send touches, tilt and microphone level as statements, and
share a screen, camera or microphone with other people in the room.
It can also pretend to be a Folk machine, for trying things without
one.

    phone / laptop                connect server                 Folk machine
    +--------------+    wss    +------------------+    wss    +---------------+
    | this page    |<--------->| rooms by public  |<--------->| connect.folk  |
    |              |           | address; relays  |           | (dials out)   |
    +------+-------+           | offers/answers   |           +-------+-------+
           |                   +------------------+                   |
           +----------- WebRTC, directly over the local network ------+
                 data channel "folk" = Folk's ordinary /ws protocol

Why it is built this way: a page needs HTTPS to use the camera,
microphone or screen, and an HTTPS page is not allowed to open
`ws://folk-whatever.local:4273`. So the machine dials *out* to a small
server, which introduces it to browsers arriving from the same public
address, and the two then connect to each other directly.

## Pieces

| Path | What it is |
| --- | --- |
| `server/room.js` | The signaling protocol. Pure logic, shared by both servers. |
| `server/worker.js` | Cloudflare Worker + one Durable Object per room. |
| `server/dev-server.js` | The same thing in Node, for local use. Also serves `web/`. |
| `web/` | The page. No build step. |
| `../builtin-programs/connect.folk` | The Folk side. Inert until you opt in. |
| `build-libdatachannel.sh` | Builds the WebRTC library `connect.folk` uses. |

## Try it with no Folk machine

    cd connect
    npm install
    npm run dev          # http://localhost:8787

Open the page in two tabs. In one, press "Simulate a Folk machine in
this tab"; in the other, press "Open scratchpad" on it.

## Turn it on for a Folk machine

Put this in a program the machine runs (for example
`~/folk-data/local-program/connect.folk`):

    Claim the connect server is "wss://connect.folk.computer/ws"

Options go after `with`:

    Claim the connect server is "ws://my-laptop.local:8787/ws" \
        with room "my-table" pairing true name "the big table"

- `room`: join a named room rather than the one for this network's
  public address. Use this when the machine and the phone do not share
  a public address (the phone opens `https://.../#my-table`).
- `pairing`: ask for a 4-digit code the first time a device connects.
  The code is printed to the console and claimed as
  `the connect pairing code is /code/`. Devices that have paired keep
  a token (stored in `~/folk-data/connect-tokens`).
- `name`: what to call the machine in the room (default: hostname).

The first run builds libdatachannel into `vendor/libdatachannel`
(needs `git cmake g++ libssl-dev`; takes a few minutes).

## What the scratchpad sends

All of it is held on the connection, so it goes away when the phone
leaves. With a device called `phone`:

    Claim phone has touch 3 at {0.41 0.77}
    Claim phone has orientation {alpha 12.0 beta -3.5 gamma 88.1}
    Claim phone has audio level 0.32

Touch positions are fractions of the display from its top-left corner.
"Run on the table" makes a program the same way `/new` does
(`web-program-connect-<device>-<id>`, with a canvas, a quad and code).

## Who can connect

The data channel is bridged to the machine's own `/ws`, which
evaluates Tcl. Two things limit who can open one:

- Neither side uses STUN or TURN, so a connection only forms if the
  browser can reach one of the machine's local addresses. That is the
  same set of people who can already open `:4273`.
- `pairing true` adds the code on top of that.

The server sees names, device kinds and the WebRTC offers and answers
(which contain local IP addresses). It never sees statements or media.
It is unauthenticated: anyone who lands in a room can see who is in
it.

## Deploying

    npm run deploy       # copies ../lib/folk.js into web/, then wrangler deploy

`wrangler.toml` has a commented-out `routes` line for the custom
domain. The Worker has been run under `wrangler dev` but not deployed.

## Tests

    npm test             # room logic (no dependencies)
    npm run test:e2e     # three browsers and the dev server (needs Playwright)
    npm run test:folk    # a browser against a real ./folk (needs Playwright,
                         # a built folk, and libdatachannel)

## Not done yet

- Media into Folk. Screen/camera/mic sharing works browser to browser
  (and to the simulator); a real machine only takes the data channel.
  libdatachannel is built without media support for now.
- Showing the pairing code on the table. It is claimed; nothing draws
  it.
- The quad placement Tcl is ported from `/new` and has not been run on
  a machine with a projector.
- A native iOS shell (Bonjour discovery, no server needed).
