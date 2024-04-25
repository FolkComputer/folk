# folk-live-build

Builds a bootable Folk OS image.

To run Folk on a PC, [download the latest pre-built Folk image for USB
stick from the Releases
page.](https://github.com/FolkComputer/folk-live-build/releases)
Follow the instructions there.

---

Below are details on how the Folk OS image is constructed; **you don't
need to worry about any of the below if you're just trying to install
Folk.**

## Key files

- `folk-live/`: becomes writable partition on disk, including Folk repo
- `config/package-lists/folk.list.chroot`: apt packages
- `config/hooks/normal/9999-setup-folk.hook.chroot`: executed in
  `/` chroot at image construction time
- `config/includes.chroot_after_packages/`: copied into `/` at boot
- `config/includes.chroot_after_packages/lib/live/config/9999-folk`:
  executed at boot

## How to build folk-amd64.img from scratch

You need to build on a computer running amd64 Debian Bookworm. (Use a
virtual machine if you need to. A Folk system built by folk-live-build
itself should work, though, whether on a virtual or physical machine.)

```
# apt install live-build parted dosfstools
$ git submodule update --init
$ make
```

emits `folk-amd64.img`.

(It runs from scratch each time -- can take 30 minutes or more.)

## How it works

Image (-> USB drive) contains Master Boot Record with:

1. 'Binary' ext4 partition (~1.3GB)
   - Contains a bunch of stuff (?), including the SquashFS file of
     the chroot filesystem, which ultimately maps to / in the
     running system
   - Could be fat32 or iso9660 I think but ext4 is reliable

2. EFI system partition (100MB)
   - syslinux-efi bootloader
   - Linux kernel image (annoying if you update kernel but this is a
     sealed live USB so that shouldn't be an issue)

3. Writable FAT32 partition (~500MB)
   - Contains /folk with Folk evaluator code and virtual programs,
     /folk-printed-programs, etc.
   - Contains setup.folk which you can edit to set runtime settings
     (Wi-Fi credentials)
   - Designed to automount on all operating systems when the USB is
     plugged in, to make it easy to configure Wi-Fi and other stuff
     before boot

Cannot have FAT32 partition be same as efi partition (and use iso
loopback) because macOS (and probably other OSes?) won't automount an
efi partition.

#### Build process

The build process uses Debian live-build to build a live image, then
appends EFI system partition (to make it bootable on UEFI machines)
and a writable partition (to make it easy for end-user to set config
settings and update Folk).

(live-build can make a complete bootable disk image on its own, but
only in iso-hybrid mode, which doesn't let you modify the partition
table to add the writable partition, so we instead use hdd mode and
modify the partition table ourselves.)

1. Run live-build, emit a disk image (with MBR with only a binary
   partition. not bootable on many modern systems)

2. Use parted to mutate the disk image to add EFI system partition

3. Copy syslinux-efi bootloader and bootloader config and Linux kernel
   etc onto EFI system partition

4. Use parted to mutate the disk image to add the writable FAT32 partition

## References

- <https://ianlecorbeau.github.io/blog/debian-live-build.html>
- <https://manpages.debian.org/testing/live-build/lb_config.1.en.html>
- <https://live-team.pages.debian.net/live-manual/html/live-manual/index.en.html>

## License

Apache 2.0

## TODO

- ~~Replace "NO NAME" title of FAT32 writable partition with Folk name~~
- Test MBR+EFI on various systems (BIOS, UEFI, Chromebook, Beelink,
  NUC, UTM)
- ~~Make fstab automount the writable partition (how do we know it's
  /dev/sdb2?)~~
- ~~Put Wi-Fi config on writable partition~~
- Allow setting display and webcam from setup.folk
- Figure out disk installation process
- Handle printed programs, calibration (make folk prefix that goes to folk-live?)

