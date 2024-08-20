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

# Install the required tools
sudo apt-get update
sudo apt-get install -y debootstrap squashfs-tools xorriso syslinux isolinux genisoimage

# Create necessary directories
mkdir -p image/isolinux
mkdir -p chroot

# Bootstrap the base system
sudo debootstrap --arch=${arch} ${release} chroot ${mirror}

# Copying the sources.list in chroot
sudo cp -v sources.${release}.list chroot/etc/apt/sources.list

# Mounting necessary pseudo-filesystems for the chroot
sudo mount --rbind /sys chroot/sys
sudo mount --rbind /dev chroot/dev
sudo mount -t proc none chroot/proc

# Working inside the chroot
sudo chroot chroot <<EOF
export DEBIAN_FRONTEND=noninteractive
locale-gen en_US.UTF-8

# Handle initctl override
dpkg-divert --local --rename --add /sbin/initctl
ln -s /bin/true /sbin/initctl

# Install core and base packages
apt-get -qq update
apt-get -qq -y install ubuntu-standard casper lupin-casper laptop-detect os-prober linux-generic
apt-get -qq -y install xorg xinit sddm lxqt-core lxqt-qtplugin lxqt-notificationd

# Clean up
apt-get -qq clean
rm -rf /tmp/*

# Reverting initctl override
rm /sbin/initctl
dpkg-divert --rename --remove /sbin/initctl
exit
EOF

# Unmount pseudo-filesystems
sudo umount -lfr chroot/proc
sudo umount -lfr chroot/sys
sudo umount -lfr chroot/dev

# Copy the kernel and initrd from the chroot
sudo cp --verbose chroot/boot/vmlinuz-* image/casper/vmlinuz || { echo "Failed to copy vmlinuz"; exit 1; }
sudo cp --verbose chroot/boot/initrd.img-* image/casper/initrd.lz || { echo "Failed to copy initrd.img"; exit 1; }

# Creating the filesystem manifest
sudo chroot chroot dpkg-query -W --showformat='${Package} ${Version}\n' | sudo tee image/casper/filesystem.manifest
sudo cp -v image/casper/filesystem.manifest image/casper/filesystem.manifest-desktop

# Remove unnecessary packages from the desktop manifest
REMOVE='ubiquity ubiquity-frontend-gtk ubiquity-frontend-kde casper lupin-casper live-initramfs user-setup discover1 xresprobe os-prober libdebian-installer4'
for i in $REMOVE; do
    sudo sed -i "/${i}/d" image/casper/filesystem.manifest-desktop
done

# Compress the live filesystem
sudo mksquashfs chroot image/casper/filesystem.squashfs -noappend -no-progress

# Copy ISOLINUX bootloader files
sudo cp /usr/lib/ISOLINUX/isolinux.bin image/isolinux/ || { echo "Failed to copy isolinux.bin"; exit 1; }
sudo cp /usr/lib/syslinux/modules/bios/* image/isolinux/ || { echo "Failed to copy syslinux modules"; exit 1; }

# Verify the contents of the isolinux directory
ls -l image/isolinux/

# Create the isolinux.cfg file
cat <<EOF | sudo tee image/isolinux/isolinux.cfg
DEFAULT linux
LABEL linux
  KERNEL /casper/vmlinuz
  APPEND initrd=/casper/initrd.lz boot=casper quiet splash ---
EOF

# Generate the ISO image
IMAGE_NAME="CUSTOM ${release} $(date -u +%Y%m%d) - ${arch}"
ISOFILE=CUSTOM-${release}-$(date -u +%Y%m%d)-${arch}.iso

sudo genisoimage -r -V "$IMAGE_NAME" -cache-inodes -J -l \
  -b isolinux/isolinux.bin -c isolinux/boot.cat \
  -no-emul-boot -boot-load-size 4 -boot-info-table \
  -o ../$ISOFILE image/ || { echo "Failed to generate ISO"; exit 1; }

# Generate the md5sum.txt file
sudo find image/ -type f -print0 | sudo xargs -0 md5sum | grep -v "\./md5sum.txt" | sudo tee image/md5sum.txt

# Output ISO file location and size
echo "ISO file created: ../$ISOFILE"
ls -lh ../$ISOFILE
cd ..
