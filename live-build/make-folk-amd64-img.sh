#!/bin/bash -eux

EFI_PART_SIZE_MIB=5
WRITABLE_PART_SIZE_MIB=512

ORIG_IMG=$1
FOLK_IMG=$2
cp $ORIG_IMG $FOLK_IMG

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

# Create and format the writable FAT32 partition:
parted -s $FOLK_IMG mkpart primary fat32 \
	$(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))MiB \
	100%
sudo losetup --detach /dev/loop0 || true
sudo losetup --offset $(($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB))MiB /dev/loop0 $FOLK_IMG
mkdosfs -F32 /dev/loop0

# Mount the writable FAT32 partition:
sudo mkdir -p /mnt/folk-img-writable
sudo mount -t vfat -o uid=$USER,gid=$USER \
     -o loop,offset=$((($ORIG_SIZE_MIB + $EFI_PART_SIZE_MIB) * 1024 * 1024)),rw \
     $FOLK_IMG /mnt/folk-img-writable

# Copy Folk into mounted FAT32 filesystem:
cp -r $(dirname "$0")/folk /mnt/folk-img-writable
# TODO: make base config file in FAT32 filesystem?

sudo umount /mnt/folk-img-writable
