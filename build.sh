#!/bin/bash
# build.sh -- creates the LiveCD ISO

set -eux

export LC_ALL=en_US.UTF-8
export LANG=en_US.UTF-8
export LANGUAGE=en_US.UTF-8

# Arch to build for, i386 or amd64
arch=${1:-amd64}
# Ubuntu mirror to use
mirror=${2:-"http://archive.ubuntu.com/ubuntu/"}
# Ubuntu release to add as a base by debootstrap
release=${4:-xenial}
# Language for GNOME
gnomelanguage=${3:-'{en}'}

# Installing the tools that need to be installed
sudo apt-get update
sudo apt-get install -y debootstrap squashfs-tools xorriso syslinux isolinux genisoimage

# Creating necessary directories
mkdir -p image/isolinux
mkdir -p chroot

# Bootstrap the base system
sudo debootstrap --arch=${arch} ${release} chroot ${mirror}

# Copying the sources.list in chroot
sudo cp -v sources.${release}.list chroot/etc/apt/sources.list

# Mounting needed pseudo-filesystems for the chroot
sudo mount --rbind /sys chroot/sys
sudo mount --rbind /dev chroot/dev
sudo mount -t proc none chroot/proc

# Working inside the chroot
sudo chroot chroot <<EOF
# Set up environment
export CASPER_GENERATE_UUID=1
export HOME=/root
export TTY=unknown
export TERM=vt100
export LANG=C
export DEBIAN_FRONTEND=noninteractive
export LIVE_BOOT_SCRIPTS="casper lupin-casper"

# This solves the setting up of locale problem for chroot
locale-gen en_US.UTF-8

# To allow a few apps using upstart to install correctly
dpkg-divert --local --rename --add /sbin/initctl
ln -s /bin/true /sbin/initctl

# Installing wget and other necessary packages
apt-get -qq install wget apt-transport-https

# Add key for third-party repo
apt-key update
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys E1098513
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 1EBD81D9
apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 91E7EE5E

# Update in-chroot package database
apt-get -qq update
apt-get -qq -y upgrade

# Install core packages
apt-get -qq -y --purge install ubuntu-standard casper lupin-casper \
  laptop-detect os-prober linux-generic

# Install base packages
apt-get -qq -y install xorg xinit sddm
# Install LXQt components
apt-get -qq -y install lxqt-core lxqt-qtplugin lxqt-notificationd
apt-get -f -qq install

# Clean up the chroot environment
apt-get -qq clean
rm -rf /tmp/*

# Reverting earlier initctl override
rm /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl
exit
EOF

# Unmount pseudo-filesystems for the chroot
sudo umount -lfr chroot/proc
sudo umount -lfr chroot/sys
sudo umount -lfr chroot/dev

# Preparing image directory
tar xf image-amd64.tar.lzma

# Copying the kernel and initrd from the chroot
sudo cp --verbose -rf chroot/boot/vmlinuz-* image/casper/vmlinuz
sudo cp --verbose -rf chroot/boot/initrd.img-* image/casper/initrd.lz

# Creating file-system manifests
sudo chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee image/casper/filesystem.manifest
sudo cp -v image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop
REMOVE='ubiquity ubiquity-frontend-gtk ubiquity-frontend-kde casper lupin-casper live-initramfs user-setup discover1 xresprobe os-prober libdebian-installer4'
for i in $REMOVE
do
    sudo sed -i "/${i}/d" image/casper/filesystem.manifest-desktop
done

# Squashing the live filesystem (Compressing the chroot)
sudo mksquashfs chroot image/casper/filesystem.squashfs -noappend -no-progress

# Copying isolinux.bin and necessary files
sudo cp /usr/lib/ISOLINUX/isolinux.bin image/isolinux/
sudo cp /usr/lib/syslinux/modules/bios/* image/isolinux/

# Creating a basic isolinux.cfg file
cat <<EOF | sudo tee image/isolinux/isolinux.cfg
DEFAULT linux
LABEL linux
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.lz boot=casper quiet splash ---
EOF

# Creating the ISO image from the tree
IMAGE_NAME=${IMAGE_NAME:-"CUSTOM ${release} $(date -u +%Y%m%d) - ${arch}"}
ISOFILE=CUSTOM-${release}-$(date -u +%Y%m%d)-${arch}.iso

sudo genisoimage -r -V "$IMAGE_NAME" -cache-inodes -J -l \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -p "${DEBFULLNAME:-$USER} <${DEBMAIL:-on host $(hostname --fqdn)}>" \
  -A "$IMAGE_NAME" \
  -o ../$ISOFILE .

# Generate md5sum.txt checksum file
sudo find image/ -type f -print0 | sudo xargs -0 md5sum | grep -v "\./md5sum.txt" | sudo tee image/md5sum.txt

# Output ISO file location and size
echo "ISO file created: ../$ISOFILE"
ls -lh ../$ISOFILE
