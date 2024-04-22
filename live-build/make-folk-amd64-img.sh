#!/bin/bash -eux

EFI_PART_SIZE_MIB=100
WRITABLE_PART_SIZE_MIB=512

ORIG_IMG=$1
FOLK_IMG=$2
cp $ORIG_IMG $FOLK_IMG

ORIG_SIZE_MIB=$(parted -s $FOLK_IMG unit MiB print free | grep 'Disk /' | cut -d ' ' -f3 | sed 's/MiB//')

# Add space for EFI system partition + writable FAT32 partition:
dd if=/dev/zero bs=1M count=$(($EFI_PART_SIZE_MIB + $WRITABLE_PART_SIZE_MIB)) >> $FOLK_IMG

# Create and format the EFI system partition:
parted -s $FOLK_IMG mkpart primary fat32 \
	${ORIG_SIZE_MIB}MiB $(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))MiB \
	set 2 boot on \
	set 2 esp on
mkdosfs --offset $(($ORIG_SIZE_MIB * 1024 * 1024 / 512)) -F32 $FOLK_IMG

# Mount the EFI system partition and copy EFI boot files to it:
sudo mkdir -p /mnt/folk-img-efi
sudo mount -t vfat -o uid=$USER,gid=$USER \
     -o loop,offset=$(($ORIG_SIZE_MIB * 1024 * 1024)),rw \
     $FOLK_IMG /mnt/folk-img-efi

mkdir -p /mnt/folk-img-efi/live
cp binary/live/initrd.img /mnt/folk-img-efi/live
cp binary/live/vmlinuz /mnt/folk-img-efi/live
mkdir -p /mnt/folk-img-efi/efi/boot
cp binary/boot/extlinux/extlinux.conf /mnt/folk-img-efi/efi/boot/syslinux.cfg
cp -r binary/boot/extlinux/* /mnt/folk-img-efi/efi/boot
cp -r chroot/usr/lib/syslinux/modules/efi64/* /mnt/folk-img-efi/efi/boot
cp -r chroot/usr/lib/SYSLINUX.EFI/efi64/syslinux.efi* /mnt/folk-img-efi/efi/boot/bootx64.efi

sudo umount /mnt/folk-img-efi

# Create and format the writable FAT32 partition:
EFI_START_MIB=$(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))
parted -s $FOLK_IMG mkpart primary fat32 \
	${EFI_START_MIB}MiB 100%
mkdosfs --offset $(($EFI_START_MIB * 1024 * 1024 / 512)) -F32 -n "FOLK-LIVE" $FOLK_IMG

# Mount the writable FAT32 partition:
sudo mkdir -p /mnt/folk-img-writable
sudo mount -t vfat -o uid=$USER,gid=$USER \
     -o loop,offset=$(($EFI_START_MIB * 1024 * 1024)),rw \
     $FOLK_IMG /mnt/folk-img-writable

# Copy writable partition content (including Folk repo) into mounted
# FAT32 filesystem:
cp -r folk-live/* /mnt/folk-img-writable
# TODO: make base config file in FAT32 filesystem?

sudo umount /mnt/folk-img-writable
