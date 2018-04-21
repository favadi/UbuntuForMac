#!/bin/bash
# https://nixaid.com/linux-on-macbookpro/

set -euxo pipefail

usage() {
    echo "Usage: $(basename "$0") <Ubuntu ISO file>"
}

if [ "$#" != "1" ]; then
    usage
    exit 1
fi

readonly prefix="UMac"
readonly iso_path="$1"
readonly iso_file="$(basename "$iso_path")"
readonly tmp_mount="$(mktemp -d)"
readonly tmp_dir="$(mktemp -d)"
readonly volume="UbuntuForMac"
readonly remastered_file="$(dirname "$iso_path")/$prefix-$iso_file"
readonly script_dir="$(dirname "$(readlink -f "$0")")"

sudo mount -o loop "$iso_path" "$tmp_mount"
rsync -a "$tmp_mount/" "$tmp_dir/"
sudo umount "$tmp_mount"
sudo rm -rf "$tmp_mount"

pushd "$tmp_dir/"
sudo unsquashfs ./casper/filesystem.squashfs

sudo mount --bind /dev ./squashfs-root/dev/
chroot ./squashfs-root /bin/bash <<'EOF'
PS1="(chroot) $PS1"
LC_ALL=C
HOME=/root
export PS1 HOME LC_ALL

get_kernel_version() {
		     dpkg -s "$1" |\
		      grep Version | \
		      awk '{print $2}' | \
		      awk -F '.' '{print $1"."$2"."$3"-"$4"-generic"}'
}

mount -t proc none /proc
mount -t sysfs none /sys
mount -t devpts none /dev/pts

mv /etc/resolv.conf /etc/resolv.conf.bak
echo 'nameserver 8.8.8.8' | tee /etc/resolv.conf

apt-get -qqy update
apt-get -qqy dist-upgrade
apt-get -qqy autoremove

os_release="$(lsb_release -r | awk '{print $2}')"
hwe_pkg=linux-generic-hwe-$os_release
non_hwe_pkg=linux-generic
kernel_version=""
if dpkg -s "$hwe_pkg"; then
   kernel_version="$(get_kernel_version "$hwe_pkg")"
else
   kernel_version="$(get_kernel_version "$non_hwe_pkg")"
fi
echo -n "$kernel_version" > /root/kernel_version

apt-get -qqy install git dkms

echo -e "\n# macbook12-spi-drivers\napplespi\nappletb\nspi_pxa2xx_platform\nintel_lpss_pci" >> /etc/initramfs-tools/modules
pushd /usr/local/src
git clone https://github.com/roadrunner2/macbook12-spi-driver.git
cd ./macbook12-spi-driver
git checkout touchbar-driver-hid-driver
dkms add .
dkms install -m applespi -v 0.1
popd

mv /etc/resolv.conf.bak /etc/resolv.conf
umount /dev/pts
umount /sys
umount /proc
EOF
sudo umount ./squashfs-root/dev/
sudo cp "$script_dir"/61-evdev-local.hwdb ./squashfs-root/etc/udev/hwdb.d
sudo cp "$script_dir"/61-libinput-local.hwdb ./squashfs-root/etc/udev/hwdb.d
kernel_version="$(cat ./squashfs-root/root/kernel_version)"
sudo rm -rf ./squashfs-root/root/kernel_version
sudo cp ./squashfs-root/boot/vmlinuz-"$kernel_version".efi.signed ./casper/vmlinuz.efi
sudo sh -c "gunzip -c ./squashfs-root/boot/initrd.img-$kernel_version | lzma -c > ./casper/initrd.lz"
sudo rm ./casper/filesystem.squashfs
sudo mksquashfs ./squashfs-root ./casper/filesystem.squashfs
sudo rm -rf ./squashfs-root
sudo rm md5sum.txt
sudo find -type f -print0 |\
    xargs -0 sudo md5sum |\
    grep -Ev "md5sum.txt|isolinux/boot.cat" |\
    sudo tee md5sum.txt
popd

pushd "$(dirname "$tmp_dir")"
sudo apt -qqy install xorriso isolinux

sudo xorriso -as mkisofs \
     -r -V "$volume" -R -l -o "$remastered_file" \
     -c isolinux/boot.cat -b isolinux/isolinux.bin \
     -no-emul-boot -boot-load-size 4 -boot-info-table \
     -isohybrid-mbr /usr/lib/ISOLINUX/isohdpfx.bin \
     -eltorito-alt-boot \
     -e boot/grub/efi.img \
     -no-emul-boot -isohybrid-gpt-basdat "$(basename "$tmp_dir")"
popd
sudo rm -rf "$tmp_dir"
current_user=$(whoami)
sudo chown "$current_user:$current_user" "$remastered_file"
