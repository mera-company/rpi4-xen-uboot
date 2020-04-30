#!/bin/bash 

# SPDX-License-Identifier: MIT

# Copyright (c) 2019, DornerWorks, Ltd.
# Author: Stewart Hildebrand
#
# Copyright (c) 2020, MERA
# Author: Leonid Lazarev

PROXY_CFG="";
DNS_SERVER="8.8.8.8";

ARCH_CFG="arm64";
IMAGE_SIZE=2048;

# build type guest or host
BUILD_TYPE="host"; 

helpFunction()
{
   echo ""
   echo "Usage: $0 [-p proxy] [-d dns server] [-s image size]"
   echo "    -p http proxy to be used in format site.domain.com"
   echo "    -d dns server"
   echo "    -s image size in MB. Default 2048"
   echo "    -h help"
   exit 1 # Exit script after printing help
}

optstring="p:d:s:h"
while getopts $optstring opt
do
   case $opt in
      p ) PROXY_CFG="$OPTARG" ;;
      d ) DNS_SERVER="$OPTARG" ;;
      s ) IMAGE_SIZE="$OPTARG" ;; 
      h | *) helpFunction ;; # Print helpFunction in case parameter is non-existent
   esac
done


WRKDIR=$(pwd)/
SCRIPTDIR=$(cd $(dirname $0) && pwd)/

USERNAME=pi
PASSWORD=123

SALT=dw
HASHED_PASSWORD=$(perl -e "print crypt(\"${PASSWORD}\",\"${SALT}\");")
HOSTNAME=ubuntu
VARIANT=dom0

BUILD_ARCH=$ARCH_CFG

sudo apt install device-tree-compiler tftpd-hpa flex bison qemu-utils kpartx git curl qemu-user-static binfmt-support parted bc libncurses5-dev libssl-dev pkg-config python acpica-tools u-boot-tools

source ${SCRIPTDIR}toolchain-aarch64-linux-gnu.sh

DTBFILE=bcm2711-rpi-4-b.dtb


# Clone firmaware source
if [ ! -d firmware ]; then
    git clone --depth 1 https://github.com/raspberrypi/firmware.git
fi

if [ ! -d xen ]; then
    git clone git://xenbits.xen.org/xen.git
    cd xen
    git checkout RELEASE-4.13.0
    git am ${SCRIPTDIR}patches/xen/0001-XEN-on-RPi4-1GB-lmitation-workaround-XEN-tries-to-al.patch
    cd ${WRKDIR}
fi

if [ ! -d linux ]; then
    git clone --depth 1 --branch rpi-4.19.y https://github.com/raspberrypi/linux.git linux
    cd linux
    git am ${SCRIPTDIR}patches/linux/*.patch
    cd ${WRKDIR}
fi

# Clone u-boot and build
if [ ! -d u-boot ]; then
    git clone https://github.com/u-boot/u-boot.git
fi

#compile uboot for rpi4
if [ ! -s ${WRKDIR}u-boot/u-boot.bin ]; then
    cd u-boot
    if [ "${BUILD_ARCH}" == "arm64" ]; then
        make CROSS_COMPILE=aarch64-linux-gnu- rpi_arm64_defconfig
        make CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) 
    fi
    cd ${WRKDIR} 
fi

# Build xen
if [ ! -s ${WRKDIR}xen/xen/xen ]; then
    cd ${WRKDIR}xen
    if [ ! -s xen/.config ]; then
        echo "CONFIG_DEBUG=y" > xen/arch/arm/configs/arm64_defconfig
        echo "CONFIG_SCHED_ARINC653=y" >> xen/arch/arm/configs/arm64_defconfig
        make -C xen XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CONFIG_EARLY_PRINTK=8250,0xfe215040,2 defconfig
    fi
    make XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CONFIG_EARLY_PRINTK=8250,0xfe215040,2 dist-xen -j $(nproc)
    cd ${WRKDIR}
fi

# Build Linux
cd ${WRKDIR}linux
if [ "${BUILD_ARCH}" == "arm64" ]; then
    if [ ! -s ${WRKDIR}linux/.build-arm64/.config ]; then
        # utilize kernel/configs/xen.config fragment
        make O=.build-arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- bcm2711_defconfig xen.config
    fi
    make O=.build-arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) broadcom/${DTBFILE}
    if [ ! -s ${WRKDIR}linux/.build-arm64/arch/arm64/boot/Image ]; then
        echo "Building kernel. This takes a while. To monitor progress, open a new terminal and use \"tail -f buildoutput.log\""
        make O=.build-arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) > ${WRKDIR}buildoutput.log 2> ${WRKDIR}buildoutput2.log
    fi
fi
cd ${WRKDIR}


if [ ! -d bootfiles ]; then
    mkdir bootfiles
fi

cp ${WRKDIR}firmware/boot/fixup4*.dat ${WRKDIR}firmware/boot/start4*.elf bootfiles/

if [ "${BUILD_ARCH}" == "arm64" ]; then
    cp ${WRKDIR}linux/.build-arm64/arch/arm64/boot/dts/broadcom/${DTBFILE} bootfiles/
fi

#prepare u-boot script
cd boot_scripts
mkimage -A arm -T script -C none -n "RPI4 Boot script" -d "boot.cmd" boot.scr
cd ${WRKDIR}

#add the command line parameters for dom0 kernel loading
cat > bootfiles/cmdline.txt <<EOF
console=hvc0 clk_ignore_unused root=/dev/mmcblk0p2 rootwait
EOF

# https://www.raspberrypi.org/documentation/configuration/config-txt/boot.md
# We could use the kernel option to overwrite the default kernel name
# Load u-boot.bin instead of kernel
#
# Due to limitation for Arm64 mode:  https://github.com/raspberrypi/linux/issues/3093
# USB works only if the total_mem is 3G or less 
# 
cat > bootfiles/config.txt <<EOF
kernel=u-boot.bin
arm_64bit=1
device_tree=${DTBFILE}
total_mem=3072
enable_gic=1

#disable_overscan=1

# Enable audio (loads snd_bcm2835)
dtparam=audio=on

[pi4]
max_framebuffers=2

[all]

enable_jtag_gpio=1
enable_uart=1
init_uart_baud=115200
EOF

# Copy u-boot script to boot
cp ${WRKDIR}boot_scripts/boot.scr bootfiles/

# Copy u-boot binary to boot
cp ${WRKDIR}u-boot/u-boot.bin bootfiles/

# Copy xen to the boot partition
cp ${WRKDIR}xen/xen/xen bootfiles/

# Copy kernel to boot partion
if [ "${BUILD_ARCH}" == "arm64" ]; then
    cp ${WRKDIR}linux/.build-arm64/arch/arm64/boot/Image bootfiles/
fi

#copy rpi bootfiles to boot partion
if [ -d /media/${USER}/boot/ ]; then
    cp bootfiles/* /media/${USER}/boot/
    
fi

sync

MNTRAMDISK=/mnt/dom0_ramdisk/
MNTROOTFS=/mnt/dom0_rpi-arm64-rootfs/
MNTBOOT=${MNTROOTFS}boot/
IMGFILE=${MNTRAMDISK}rpixen.img

ROOTFS=${VARIANT}-ubuntu-base-18.04.3-base-${BUILD_ARCH}-prepped.tar.gz
if [ ! -s ${ROOTFS} ]; then
    ./ubuntu-base-prep.sh ${ROOTFS} ${MNTRAMDISK} ${BUILD_ARCH}  ${DNS_SERVER} ${PROXY_CFG} 
fi

unmountstuff () {
  sudo umount ${MNTROOTFS}proc || true
  sudo umount ${MNTROOTFS}dev/pts || true
  sudo umount ${MNTROOTFS}dev || true
  sudo umount ${MNTROOTFS}sys || true
  sudo umount ${MNTROOTFS}tmp || true
  sudo umount ${MNTBOOT} || true
  sudo umount ${MNTROOTFS} || true
}

mountstuff () {
  sudo mkdir -p ${MNTROOTFS}
  if ! mount | grep ${LOOPDEVROOTFS}; then
    sudo mount ${LOOPDEVROOTFS} ${MNTROOTFS}
  fi
  sudo mkdir -p ${MNTBOOT}
  sudo mount ${LOOPDEVBOOT} ${MNTBOOT}
  sudo mount -o bind /proc ${MNTROOTFS}proc
  sudo mount -o bind /dev ${MNTROOTFS}dev
  sudo mount -o bind /dev/pts ${MNTROOTFS}dev/pts
  sudo mount -o bind /sys ${MNTROOTFS}sys
  sudo mount -o bind /tmp ${MNTROOTFS}tmp
}

finish () {
  cd ${WRKDIR}
  sudo sync
  unmountstuff
  sudo kpartx -dvs ${IMGFILE} || true
  sudo rmdir ${MNTROOTFS} || true
  mv ${IMGFILE} . || true
  sudo umount ${MNTRAMDISK} || true
  sudo rmdir ${MNTRAMDISK} || true
}

trap finish EXIT


sudo mkdir -p ${MNTRAMDISK}
sudo mount -t tmpfs -o size=3g tmpfs ${MNTRAMDISK}

qemu-img create ${IMGFILE} ${IMAGE_SIZE}M
/sbin/parted ${IMGFILE} --script -- mklabel msdos
/sbin/parted ${IMGFILE} --script -- mkpart primary fat32 2048s 264191s
/sbin/parted ${IMGFILE} --script -- mkpart primary ext4 264192s -1s

LOOPDEVS=$(sudo kpartx -avs ${IMGFILE} | awk '{print $3}')
LOOPDEVBOOT=/dev/mapper/$(echo ${LOOPDEVS} | awk '{print $1}')
LOOPDEVROOTFS=/dev/mapper/$(echo ${LOOPDEVS} | awk '{print $2}')

sudo mkfs.vfat ${LOOPDEVBOOT}
sudo mkfs.ext4 ${LOOPDEVROOTFS}

sudo fatlabel ${LOOPDEVBOOT} boot
sudo e2label ${LOOPDEVROOTFS} RpiUbuntu

sudo mkdir -p ${MNTROOTFS}
sudo mount ${LOOPDEVROOTFS} ${MNTROOTFS}

sudo tar -C ${MNTROOTFS} -xf ${ROOTFS}

mountstuff

sudo cp -r bootfiles/* ${MNTBOOT}

cd ${WRKDIR}linux
if [ "${BUILD_ARCH}" == "arm64" ]; then
    sudo --preserve-env PATH=${PATH} make O=.build-arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- INSTALL_MOD_PATH=${MNTROOTFS} modules_install > ${WRKDIR}modules_install.log
fi
cd ${WRKDIR}


# Build Xen tools

if [ "${BUILD_ARCH}" == "arm64" ]; then
    CROSS_PREFIX=aarch64-linux-gnu
    XEN_ARCH=arm64
fi

# Change the shared library symlinks to relative instead of absolute so they play nice with cross-compiling
sudo chroot ${MNTROOTFS} symlinks -c /usr/lib/${CROSS_PREFIX}/

cd ${WRKDIR}xen

# TODO: --with-xenstored=oxenstored

# Ask the native compiler what system include directories it searches through.
SYSINCDIRS=$(echo $(sudo chroot ${MNTROOTFS} bash -c "echo | gcc -E -Wp,-v -o /dev/null - 2>&1" | grep "^ " | sed "s|^ /| -isystem${MNTROOTFS}|"))
SYSINCDIRSCXX=$(echo $(sudo chroot ${MNTROOTFS} bash -c "echo | g++ -x c++ -E -Wp,-v -o /dev/null - 2>&1" | grep "^ " | sed "s|^ /| -isystem${MNTROOTFS}|"))

CC="${CROSS_PREFIX}-gcc --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRS} -B${MNTROOTFS}lib/${CROSS_PREFIX} -B${MNTROOTFS}usr/lib/${CROSS_PREFIX}"
CXX="${CROSS_PREFIX}-g++ --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRSCXX} -B${MNTROOTFS}lib/${CROSS_PREFIX} -B${MNTROOTFS}usr/lib/${CROSS_PREFIX}"
LDFLAGS="-Wl,-rpath-link=${MNTROOTFS}lib/${CROSS_PREFIX} -Wl,-rpath-link=${MNTROOTFS}usr/lib/${CROSS_PREFIX}"

PKG_CONFIG=pkg-config \
PKG_CONFIG_LIBDIR=${MNTROOTFS}usr/lib/${CROSS_PREFIX}/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=${MNTROOTFS} \
LDFLAGS="${LDFLAGS}" \
./configure \
    PYTHON_PREFIX_ARG=--install-layout=deb \
    --enable-systemd \
    --disable-xen \
    --enable-tools \
    --disable-docs \
    --disable-stubdom \
    --prefix=/usr \
    --with-xenstored=xenstored \
    --build=x86_64-linux-gnu \
    --host=${CROSS_PREFIX} \
    CC="${CC}" \
    CXX="${CXX}"

PKG_CONFIG=pkg-config \
PKG_CONFIG_LIBDIR=${MNTROOTFS}usr/lib/${CROSS_PREFIX}/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=${MNTROOTFS} \
LDFLAGS="${LDFLAGS}" \
make dist-tools \
    CROSS_COMPILE=${CROSS_PREFIX}- XEN_TARGET_ARCH=${XEN_ARCH} \
    CC="${CC}" \
    CXX="${CXX}" \
    -j $(nproc)

sudo --preserve-env PATH=${PATH} \
PKG_CONFIG=pkg-config \
PKG_CONFIG_LIBDIR=${MNTROOTFS}usr/lib/${CROSS_PREFIX}/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=${MNTROOTFS} \
LDFLAGS="${LDFLAGS}" \
make install-tools \
    CROSS_COMPILE=${CROSS_PREFIX}- XEN_TARGET_ARCH=${XEN_ARCH} \
    CC="${CC}" \
    CXX="${CXX}" \
    DESTDIR=${MNTROOTFS}

sudo chroot ${MNTROOTFS} systemctl enable xen-qemu-dom0-disk-backend.service
sudo chroot ${MNTROOTFS} systemctl enable xen-init-dom0.service
sudo chroot ${MNTROOTFS} systemctl enable xenconsoled.service
sudo chroot ${MNTROOTFS} systemctl enable xendomains.service
sudo chroot ${MNTROOTFS} systemctl enable xen-watchdog.service

cd ${WRKDIR}

# It seems like the xen tools configure script selects a few too many of these backend driver modules, so we override it with a simpler list.
# /usr/lib/modules-load.d/xen.conf
sudo bash -c "cat > ${MNTROOTFS}usr/lib/modules-load.d/xen.conf" <<EOF
xen-evtchn
xen-gntdev
xen-gntalloc
xen-blkback
xen-netback
EOF

# /etc/hostname
sudo bash -c "echo ${HOSTNAME} > ${MNTROOTFS}etc/hostname"

# /etc/hosts
sudo bash -c "cat > ${MNTROOTFS}etc/hosts" <<EOF
127.0.0.1	localhost
127.0.1.1	${HOSTNAME}

# The following lines are desirable for IPv6 capable hosts
::1     ip6-localhost ip6-loopback
fe00::0 ip6-localnet
ff00::0 ip6-mcastprefix
ff02::1 ip6-allnodes
ff02::2 ip6-allrouters
EOF

# /etc/fstab
sudo bash -c "cat > ${MNTROOTFS}etc/fstab" <<EOF
proc            /proc           proc    defaults          0       0
/dev/mmcblk0p1  /boot           vfat    defaults          0       2
/dev/mmcblk0p2  /               ext4    defaults,noatime  0       1
EOF

# /etc/network/interfaces.d/eth0
sudo bash -c "cat > ${MNTROOTFS}etc/network/interfaces.d/eth0" <<EOF
auto eth0
iface eth0 inet manual
EOF
sudo chmod 0644 ${MNTROOTFS}etc/network/interfaces.d/eth0

# /etc/network/interfaces.d/xenbr0
sudo bash -c "cat > ${MNTROOTFS}etc/network/interfaces.d/xenbr0" <<EOF
auto xenbr0
iface xenbr0 inet dhcp
    bridge_ports eth0
EOF
sudo chmod 0644 ${MNTROOTFS}etc/network/interfaces.d/xenbr0

# Don't wait forever and a day for the network to come online
if [ -s ${MNTROOTFS}lib/systemd/system/networking.service ]; then
    sudo sed -i -e "s/TimeoutStartSec=5min/TimeoutStartSec=15sec/" ${MNTROOTFS}lib/systemd/system/networking.service
fi
if [ -s ${MNTROOTFS}lib/systemd/system/ifup@.service ]; then
    sudo bash -c "echo \"TimeoutStopSec=15s\" >> ${MNTROOTFS}lib/systemd/system/ifup@.service"
fi

# User account setup
sudo chroot ${MNTROOTFS} useradd -s /bin/bash -G adm,sudo -l -m -p ${HASHED_PASSWORD} ${USERNAME}
# Password-less sudo
sudo chroot ${MNTROOTFS} /bin/bash -euxc "echo \"${USERNAME} ALL=(ALL) NOPASSWD:ALL\" > /etc/sudoers.d/90-${USERNAME}-user"

df -h | grep -e "Filesystem" -e "/dev/mapper/loop"
