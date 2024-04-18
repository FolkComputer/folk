# folk-live-build

Builds a bootable Folk OS image.

You don't want this repo if you're just trying to install Folk -- you
should just download the pre-built `folk.amd64.img` from (TODO:
somewhere).

## Key files

- `config/package-lists/folk.list.chroot`: apt packages
- `config/includes.chroot_after_packages/etc/skel`: copied into `/home/folk` at boot
- `config/includes.chroot_after_packages/`: copied into `/` at boot

## How to build

You need to build on a computer running amd64 Debian Bookworm. (Use a
virtual machine if you need to. A Folk system built by folk-live-build
itself should work, though, whether on a virtual or physical machine.)

```
# apt install live-build parted
$ make
```

emits `folk.amd64.img`.

(It runs from scratch each time -- can take 30 minutes-ish.)

## How it works

Image (-> USB drive) contains Master Boot Record with:

1. EFI system partition (~1MB? ~100MB?)

2. 'Binary' partition (~1.3GB) (may be fat32, iso9660, or ext4, doesn't matter)
   - Contains a bunch of stuff, including the SquashFS file for the
     root filesystem image, which ultimately maps to / in the running
     system

3. Writable FAT32 partition (~1GB)
   - Contains /folk with Folk evaluator code and virtual programs,
     /folk-printed-programs, etc.
   - TODO: Contains config.tcl
   - Designed to automount on all operating systems when the USB is
     plugged in, to make it easy to configure Wi-Fi and other stuff
     before boot

Cannot have FAT32 partition be same as efi partition (and use iso
loopback) because macOS (and probably other OSes?) won't automount an
efi partition.

#### Build process

1. Run live-build, emit a bootable disk image (with MBR with EFI &
   binary partition)

2. Use parted to mutate the disk image to add the writable FAT32 partition

## References

- <https://ianlecorbeau.github.io/blog/debian-live-build.html>
- <https://manpages.debian.org/testing/live-build/lb_config.1.en.html>
- <https://live-team.pages.debian.net/live-manual/html/live-manual/index.en.html>
