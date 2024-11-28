#!/bin/bash -Eeux
set -o pipefail
# SPDX-License-Identifier: MIT

# Copyright (c) 2019, DornerWorks, Ltd.
# Author: Stewart Hildebrand
#
# Copyright (c) 2020, MERA
# Author: Leonid Lazarev

PROXY_CFG="";
DNS_SERVER="8.8.8.8";

ARCH_CFG="arm64";
IMAGE_SIZE=1524;

# build type guest or host
BUILD_TYPE="host"; 

helpFunction()
{
   echo ""
   echo "Usage: $0 [-p proxy] [-d dns server] [-s image size]"
   echo "    -p http proxy to be used in format site.domain.com"
   echo "    -d dns server"
   echo "    -s image size in MB. Default 1024"
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

USERNAME=domu
PASSWORD=domu
SALT=dw
HASHED_PASSWORD=$(perl -e "print crypt(\"${PASSWORD}\",\"${SALT}\");")
HOSTNAME=ubuntuDomU
VARIANT=domu

MNTRAMDISK=/mnt/domu_ramdisk/
MNTROOTFS=/mnt/domu_rpi-arm64-rootfs/
IMGFILE_NAME=ubuntuDomU.img
IMGFILE=${MNTRAMDISK}${IMGFILE_NAME}

ARTIFACTS=domu.tar

BUILD_ARCH=$ARCH_CFG

sudo apt install device-tree-compiler tftpd-hpa flex bison qemu-utils kpartx git curl qemu-user-static binfmt-support parted bc libncurses5-dev libssl-dev pkg-config python2 acpica-tools

source ${SCRIPTDIR}toolchain-aarch64-linux-gnu.sh

ROOTFS=${VARIANT}-ubuntu-base-18.04.3-base-${BUILD_ARCH}-prepped.tar.gz
if [ ! -s ${ROOTFS} ]; then
    ./ubuntu-base-prep.sh ${ROOTFS} ${MNTRAMDISK} ${BUILD_ARCH}  ${DNS_SERVER} ${PROXY_CFG} 
fi

#prepare kernel for domU

if [ ! -d linux_domu ]; then
    git clone --depth 1 --branch linux-5.5.y  http://git.kernel.org/pub/scm/linux/kernel/git/stable/linux-stable.git linux_domu
    cd ${WRKDIR}
fi

# Build Linux
cd ${WRKDIR}linux_domu
if [ "${BUILD_ARCH}" == "arm64" ]; then
    if [ ! -s ${WRKDIR}linux_domu/.build-arm64/.config ]; then
        mkdir -p ${WRKDIR}linux_domu/.build-arm64/
	cp ${WRKDIR}config/kernel/linux_5.5_domu.config ${WRKDIR}linux_domu/.build-arm64/.config
    fi
    if [ ! -s ${WRKDIR}linux_domu/.build-arm64/arch/arm64/boot/Image ]; then
        echo "Building kernel. This takes a while. To monitor progress, open a new terminal and use \"tail -f buildoutput.log\""
        make O=.build-arm64 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j $(nproc) > ${WRKDIR}buildoutput.log 2> ${WRKDIR}buildoutput2.log
    fi
fi
cd ${WRKDIR}

prepare_artifacts () {
    if [ -f ${WRKDIR}${IMGFILE_NAME} ]; then
         tar -cvf ${ARTIFACTS} ./${IMGFILE_NAME} 
         tar -rf ${ARTIFACTS} -C config/domu/ domu0.cfg
         tar -rf ${ARTIFACTS} -C config/domu/ README
         tar -rf ${ARTIFACTS} -C linux_domu/.build-arm64/arch/arm64/boot/ Image
         gzip -rf ${ARTIFACTS}
    fi
}

unmountstuff () {
  sudo umount ${MNTROOTFS}proc || true
  sudo umount ${MNTROOTFS}dev/pts || true
  sudo umount ${MNTROOTFS}dev || true
  sudo umount ${MNTROOTFS}sys || true
  sudo umount ${MNTROOTFS}tmp || true
  sudo umount ${MNTROOTFS} || true
}

mountstuff () {
  sudo mkdir -p ${MNTROOTFS}
  if ! mount | grep ${LOOPDEVROOTFS}; then
    sudo mount ${LOOPDEVROOTFS} ${MNTROOTFS}
  fi
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
  
  #prepare archive with data
  prepare_artifacts
}

trap finish EXIT


sudo mkdir -p ${MNTRAMDISK}
sudo mount -t tmpfs -o size=3g tmpfs ${MNTRAMDISK}

qemu-img create ${IMGFILE} ${IMAGE_SIZE}M

LOOPDEVROOTFS=${IMGFILE}

sudo mkfs.ext4 ${LOOPDEVROOTFS}

sudo mkdir -p ${MNTROOTFS}
sudo mount ${LOOPDEVROOTFS} ${MNTROOTFS}

sudo tar -C ${MNTROOTFS} -xf ${ROOTFS}
read -r E
mountstuff
# =====Build Xen tools=====
cd ${WRKDIR}

CROSS_PREFIX=aarch64-linux-gnu
#PLATFORM_PREFIX=aarch64-none-linux-gnu
PLATFORM_PREFIX=aarch64-linux-gnu
XEN_ARCH=arm64
# Change the shared library symlinks to relative instead of absolute so they play nice with cross-compiling
sudo chroot ${MNTROOTFS} symlinks -c /usr/lib/${CROSS_PREFIX}/

cd ${WRKDIR}xen

# TODO: --with-xenstored=oxenstored
# make XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-none-linux-gnu- clean
sudo make XEN_TARGET_ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- clean
# Ask the native compiler what system include directories it searches through.
SYSINCDIRS=$(echo $(sudo chroot ${MNTROOTFS} bash -c "echo | gcc -E -Wp,-v -o /dev/null - 2>&1" | grep "^ " | sed "s|^ /| -isystem${MNTROOTFS}|"))
SYSINCDIRSCXX=$(echo $(sudo chroot ${MNTROOTFS} bash -c "echo | g++ -x c++ -E -Wp,-v -o /dev/null - 2>&1" | grep "^ " | sed "s|^ /| -isystem${MNTROOTFS}|"))

CC="${PLATFORM_PREFIX}-gcc --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRS} -B${MNTROOTFS}lib/${CROSS_PREFIX} -B${MNTROOTFS}usr/lib/${CROSS_PREFIX}"
CXX="${PLATFORM_PREFIX}-g++ --sysroot=${MNTROOTFS} -nostdinc ${SYSINCDIRSCXX} -B${MNTROOTFS}lib/${CROSS_PREFIX} -B${MNTROOTFS}usr/lib/${CROSS_PREFIX}"
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
    --host=${PLATFORM_PREFIX} \
    CC="${CC}" \
    CXX="${CXX}"

PKG_CONFIG=pkg-config \
PKG_CONFIG_LIBDIR=${MNTROOTFS}usr/lib/${CROSS_PREFIX}/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=${MNTROOTFS} \
LDFLAGS="${LDFLAGS}" \
make dist-tools \
    CROSS_COMPILE=${PLATFORM_PREFIX}- XEN_TARGET_ARCH=${XEN_ARCH} \
    CC="${CC}" \
    CXX="${CXX}" \
    -j $(nproc)

sudo --preserve-env PATH=${PATH} \
PKG_CONFIG=pkg-config \
PKG_CONFIG_LIBDIR=${MNTROOTFS}usr/lib/${CROSS_PREFIX}/pkgconfig:${MNTROOTFS}usr/share/pkgconfig \
PKG_CONFIG_SYSROOT_DIR=${MNTROOTFS} \
LDFLAGS="${LDFLAGS}" \
make install-tools \
    CROSS_COMPILE=${PLATFORM_PREFIX}- XEN_TARGET_ARCH=${XEN_ARCH} \
    CC="${CC}" \
    CXX="${CXX}" \
    DESTDIR=${MNTROOTFS}

sudo chroot ${MNTROOTFS} systemctl enable xen-qemu-dom0-disk-backend.service
sudo chroot ${MNTROOTFS} systemctl enable xen-init-dom0.service
sudo chroot ${MNTROOTFS} systemctl enable xenconsoled.service
sudo chroot ${MNTROOTFS} systemctl enable xendomains.service
sudo chroot ${MNTROOTFS} systemctl enable xen-watchdog.service

cd ${WRKDIR}
# ===== Build Xen tools over=====
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
/dev/xvda       /               ext4    defaults,noatime  0       1
EOF

# /etc/network/interfaces.d/eth0
sudo bash -c "cat > ${MNTROOTFS}etc/network/interfaces.d/eth0" <<EOF
auto eth0
iface eth0 inet dhcp
EOF
sudo chmod 0644 ${MNTROOTFS}etc/network/interfaces.d/eth0


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
