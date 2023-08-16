# peer

Adds "./vendor" to the `auto_path` variable.

Creates a `peersBlacklist` dict.

## functions

- `::peer {process {dieOnDisconnect false}}`: creates a namespace `::Peers::$process` with the following functions:

  - `log {s}`: Log the process name and the string `s`
  - `setupSock`: try and setup the websocket connection
  - `handleWs {chan type msg}`: depending on the type, handle a websocket message or error out
    - type "connect": log connected, and establish a peering in reverse direction, which will implicitly run in a `::Peers::X` namespace
    - type "disconnect": log disconnected, and if `dieOnDisconnect` is true, exit with code 0. Otherwise set `connected` to false and run `setupSock` after 2s
    - type "error": log the error message `msg` and run `setupSock` after 2s
    - type "text": evaluate `msg`
    - type "ping" or "pong": do nothing
  - `run {msg}`: send the message `msg` over the websocket channel, telling the remote instance to evaluate `msg`
  - `init {n shouldDieOnDisconnect}`: set `process` to `n`, then setup the socket, set dieOnDisconnect value, and wait till `connected` becomes true

---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)