# folk-live-build

## Key files

- `config/package-lists/folk.list.chroot`: apt packages

## How to build

```
# lb clean
$ lb config
# lb build
```

emits `live-image-amd64.hybrid.iso`

You have to do this each time; not sure how to incrementally rebuild
yet.

## References

See <https://ianlecorbeau.github.io/blog/debian-live-build.html>
