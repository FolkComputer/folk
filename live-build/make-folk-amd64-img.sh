#!/bin/bash -eux

EFI_PART_SIZE_MIB=5
WRITABLE_PART_SIZE_MIB=512

FOLK_IMG=folk-amd64.img
sudo install -o $USER -g $USER live-image-amd64.img $FOLK_IMG

ORIG_SIZE_MIB=$(parted -s $FOLK_IMG unit MiB print free | grep 'Disk /' | cut -d ' ' -f3 | sed 's/MiB//')

# Add space for EFI system partition + writable FAT32 partition:
dd if=/dev/zero bs=1M count=$(($EFI_PART_SIZE_MIB + $WRITABLE_PART_SIZE_MIB)) >> $FOLK_IMG

# Create and format the EFI system partition:
parted -s $FOLK_IMG mkpart primary fat32 \
	${ORIG_SIZE_MIB}MiB \
	$(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))MiB \
	set 2 boot on \
	set 2 esp on
sudo chown $USER /dev/loop0
sudo losetup --detach /dev/loop0 || true
sudo losetup --offset ${ORIG_SIZE_MIB}MiB /dev/loop0 $FOLK_IMG
mkdosfs -F32 /dev/loop0

# TODO: grub-install

# Create and format the writable FAT32 partition:
parted -s $FOLK_IMG mkpart primary fat32 \
	$(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))MiB \
	100%
sudo losetup --detach /dev/loop0 || true
sudo losetup --offset $(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))MiB /dev/loop0 $FOLK_IMG
mkdosfs -F32 /dev/loop0
# TODO: mount FAT32 filesystem, clone Folk into it
# TODO: make base config file in FAT32 filesystem?

# mount -tvfat /dev/loop0 /mnt/hdd
# cp $< /mnt/hdd
