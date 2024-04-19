#!/bin/bash -eux

WRITABLE_PART_SIZE_MIB=512

ORIG_IMG=$1
FOLK_IMG=$2
cp $ORIG_IMG $FOLK_IMG

# Add space for the writable FAT32 partition:
dd if=/dev/zero bs=1M count=$WRITABLE_PART_SIZE_MIB >> $FOLK_IMG

# Create and format the writable FAT32 partition:
(
    echo n # Create new partition
    echo p # Primary partition
    echo; echo; echo # Default partition number (should be 3) & first sector & last sector
    echo t # Change partition type
    echo 3 # Partition 3
    echo b # Type b (W95 FAT32)
    echo w # Write updated partition table
) | fdisk --wipe never --type dos $FOLK_IMG
# (Yes, this is cursed, but fdisk has the right behavior with
# iso-hybrid images, according to
# <https://dvilcans.com/debian-persistent-live/> and
# <https://unix.stackexchange.com/questions/618615/create-another-partition-on-free-space-of-usb-after-dd-installing-debian>.
# I don't trust sfdisk or parted.)

START_SECTOR=$(fdisk --wipe=never --type dos --list $FOLK_IMG | grep 'W95 FAT32' | tr -s ' ' | cut -d' ' -f2)
START_BYTES=$(($START_SECTOR * 512))
mkdosfs -F 32 --offset $START_SECTOR $FOLK_IMG

sudo mkdir -p /mnt/folk-img-writable
sudo mount -t vfat -o uid=$USER,gid=$USER -o loop,offset=$START_BYTES,rw $FOLK_IMG /mnt/folk-img-writable

# Copy Folk into mounted FAT32 filesystem
cp -r $(dirname "$0")/folk /mnt/folk-img-writable
# TODO: make base config file in FAT32 filesystem?

sudo umount /mnt/folk-img-writable
