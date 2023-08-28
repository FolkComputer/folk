# Processes Library

## functions

- `On-process {name body}`: run `body` in a new process, setting up all the peering and lexical environment code

## namespacs

### Zygote

The zygote is a process that's forked off during Folk
startup. It can fork itself to create subprocesses on demand.

- `init {}`: fork Folk to create a zygote process, setting the current state as the startup state for the subprocesses
- `zygote {}`: the Zygote's main loop
- `spawn {code}`: puts the pipe and `code`

---
CC-BY-SA 2023 Arcade Wise
(We can change the license if y'all want, I just wanted to avoid copyright issues)