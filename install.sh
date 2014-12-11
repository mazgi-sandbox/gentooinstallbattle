#!/bin/bash -eu

function cleanup() {
umount -fl /mnt/gentoo/proc 2> /dev/null || true
umount -fl /mnt/gentoo/dev 2> /dev/null || true
umount -fl /mnt/gentoo/sys 2> /dev/null || true
umount -f /mnt/gentoo/boot/efi 2> /dev/null || true
umount -f /mnt/gentoo/usr/portage 2> /dev/null || true
umount -f /mnt/gentoo/var/log 2> /dev/null || true
umount -f /mnt/gentoo/var 2> /dev/null || true
umount -fl /mnt/gentoo 2> /dev/null || true
umount -fl /mnt/btrfs 2> /dev/null || true
}
trap 'cleanup' ERR

echo 'Hello, Gentoo!'
cleanup

if [ -z "${ROOT_PASSWORD}" ]; then
  declare ROOT_PASSWORD="root"
fi

declare PATHNAME_STAGE3="$(curl -L ftp://ftp.iij.ad.jp/pub/linux/gentoo/releases/amd64/autobuilds/latest-stage3-amd64.txt | tail -1)"
declare DIRNAME_STAGE3="$(dirname ${PATHNAME_STAGE3})"
declare FILENAME_STAGE3="$(basename ${PATHNAME_STAGE3})"

if [ $(dmesg|grep -E '\s+EFI\s+v[0-9]+\.[0-9]+' -q) ]; then
  declare BOOT_FROM_UEFI="yes"
fi

if [ -z "${TARGET_DEVICE}" ]; then
  declare TARGET_DEVICE="/dev/sda"
fi
declare PARTITION_BOOT_SIZE="4M"
declare PARTITION_BOOT_TYPE="ef02"
if [ ${BOOT_FROM_UEFI} ];then
  PARTITION_BOOT_SIZE="512M"
  PARTITION_BOOT_TYPE="ef00"
fi
declare PARTITION_SWAP_SIZE="2G"
if [ 8 -ge $(free -g|grep -E '^Mem:'|tr -s ' '|cut -d' ' -f2) ]; then
  PARTITION_SWAP_SIZE="4G"
fi

if [ ! -b "${TARGET_DEVICE}" ]; then
  echo -n "Please type target device(e.g. /dev/vda): "
  while true
  do
    read device_path
    if [ -b "${device_path}" ]; then
      TARGET_DEVICE=${device_path}
      break
    else
      echo -n "Device not fount. retype target device: "
    fi
  done
fi

# create paritions

gdisk ${TARGET_DEVICE}<<EOF
o
y
n
1

+${PARTITION_BOOT_SIZE}
${PARTITION_BOOT_TYPE}
n
2

+${PARTITION_SWAP_SIZE}
8200
n
3


8300
w
y
EOF

# format filesystems

if [ $BOOT_FROM_UEFI ];then
  mkfs.vfat -F32 ${TARGET_DEVICE}1
else
  mkfs.vfat ${TARGET_DEVICE}1
fi

mkswap ${TARGET_DEVICE}2

mkfs.btrfs -f ${TARGET_DEVICE}3

mkdir -p /mnt/btrfs && mount ${TARGET_DEVICE}3 /mnt/btrfs && cd /mnt/btrfs
btrfs subvolume create gentoo
btrfs subvolume create usr-portage
btrfs subvolume create var
btrfs subvolume create var-log

mount -odefaults,subvol=gentoo,compress=lzo,autodefrag ${TARGET_DEVICE}3 /mnt/gentoo
cd /mnt/gentoo
if [ $BOOT_FROM_UEFI ];then
  mkdir -p boot/efi
  mount ${TARGET_DEVICE}1 /mnt/gentoo/boot/efi
fi
mkdir -p usr/portage var

mount -odefaults,subvol=usr-portage,compress=lzo,autodefrag ${TARGET_DEVICE}3 /mnt/gentoo/usr/portage
mount -odefaults,subvol=var,compress=lzo,autodefrag ${TARGET_DEVICE}3 /mnt/gentoo/var
mkdir -p /mnt/gentoo/var/log
mount -odefaults,subvol=var-log,compress=gzip,autodefrag ${TARGET_DEVICE}3 /mnt/gentoo/var/log

curl -LO "ftp://ftp.iij.ad.jp/pub/linux/gentoo/snapshots/portage-latest.tar.xz"
curl -LO "ftp://ftp.iij.ad.jp/pub/linux/gentoo/releases/amd64/current-iso/${FILENAME_STAGE3}"

tar xfp "${FILENAME_STAGE3}"
tar xf "portage-latest.tar.xz" -C usr

mount -t proc none /mnt/gentoo/proc
mount --rbind /dev /mnt/gentoo/dev
mount --rbind /sys /mnt/gentoo/sys

cat<<'EOF'>/mnt/gentoo/etc/portage/make.conf
CFLAGS="-O2 -pipe"
CXXFLAGS="${CFLAGS}"
CHOST="x86_64-pc-linux-gnu"
USE="-bindist mmx sse sse2"
USE="$USE -introspection"
USE="$USE bash-completion zsh-completion vim-syntax"
USE="$USE git"
USE="$USE jemalloc aio"
FEATURES="buildpkg distcc"
PORTDIR="/usr/portage"
DISTDIR="${PORTDIR}/distfiles"
PKGDIR="${PORTDIR}/packages"
SYNC="rsync://rsync.jp.gentoo.org/gentoo-portage"
GENTOO_MIRRORS="ftp://ftp.iij.ad.jp/pub/linux/gentoo/ http://ftp.iij.ad.jp/pub/linux/gentoo/ rsync://ftp.iij.ad.jp/pub/linux/gentoo/"
GRUB_PLATFORMS="emu efi-64 efi-32 pc"
EOF
echo " MAKEOPTS=\"-j$(($(nproc)+2))\"" >> /mnt/gentoo/etc/portage/make.conf

cat<<'EOF'>/mnt/gentoo/etc/locale.gen
en_US ISO-8859-1
en_US.UTF-8 UTF-8
ja_JP.EUC-JP EUC-JP
ja_JP.UTF-8 UTF-8
ja_JP EUC-JP
EOF

cat<<EOF>/mnt/gentoo/etc/fstab
${TARGET_DEVICE}3               /               btrfs           defaults,subvol=gentoo,compress=lzo,autodefrag  0 1
${TARGET_DEVICE}3               /usr/portage    btrfs           defaults,subvol=usr-portage,compress=lzo,autodefrag     0 1
${TARGET_DEVICE}3               /var            btrfs           defaults,subvol=var,compress=lzo,autodefrag     0 1
${TARGET_DEVICE}3               /var/log        btrfs           defaults,subvol=var-log,compress=gzip,autodefrag        0 1
${TARGET_DEVICE}2               none            swap            sw              0 0
EOF
if [ $BOOT_FROM_UEFI ];then
  echo '${TARGET_DEVICE}1               /boot/efi       vfat            defaults        0 1' >> /mnt/gentoo/etc/fstab
fi

cat /etc/resolv.conf > /mnt/gentoo/etc/resolv.conf
cat /mnt/gentoo/usr/share/zoneinfo/Japan > /mnt/gentoo/etc/localtime

cat<<'EOF'>/mnt/gentoo/chroot.sh
#!/bin/bash -e
env-update
source /etc/profile
export PS1="(chroot)$PS1"
emerge --sync -q
emerge -uvq genkernel gentoo-sources gentoolkit linux-firmware grub btrfs-progs xfsprogs vim zsh tmux
EOF
echo "genkernel --makeopts=-j$(($(nproc)+2)) all" >> /mnt/gentoo/chroot.sh
if [ $BOOT_FROM_UEFI ];then
  echo 'grub2-install --target=x86_64-efi' >> /mnt/gentoo/chroot.sh
else
  echo "grub2-install ${TARGET_DEVICE}" >> /mnt/gentoo/chroot.sh
fi
cat<<'EOF'>>/mnt/gentoo/chroot.sh
grub2-mkconfig -o /boot/grub/grub.cfg
EOF
chmod a+x chroot.sh
chroot /mnt/gentoo /chroot.sh

