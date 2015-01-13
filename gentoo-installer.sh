#/bin/bash



LOCAL_ROOTFS=/mnt/lvm_root
LVM_DEV=/dev/vg

LVM_ROOT=lvm_root
LVM_SWAP=lvm_swap
LVM_USR=lvm_usr
LVM_VAR=lvm_var
LVM_HOME=lvm_home

VGNAME=vg

MAPPER_DEV=/dev/mapper
CRYPTONAME=cryptextX


################################################
_help()
{
  echo "$0 -r root.tar.bz2 -d /dev/sdX"
  
  echo "$0 -d /dev/sdX -m (open and mount device)"
  
  echo "$0 -d /dev/sdX -u (close and umount device)"
}
################################################

  
_run_as_root()
{
  # Note: assuming uid==0 is root -- might break with userns??
  if [ "$(id -u)" != "0" ]; then
	  echo "This script should be run as 'root'"
	  exit 1
  fi
}


_cryptsetup()
{
  cryptsetup -c aes-xts-plain64:sha256 -y -s 512 luksFormat $DEVICE
  cryptsetup luksOpen $DEVICE $CRYPTONAME
}


_lvm()
{
  echo "create LVMs ..."
  pvcreate ${MAPPER_DEV}/${CRYPTONAME} > /dev/null
  vgcreate -s64M $VGNAME ${MAPPER_DEV}/${CRYPTONAME} > /dev/null
  
  lvcreate -n ${LVM_ROOT} -L 30G $VGNAME > /dev/null
  lvcreate -n ${LVM_SWAP} -L 4G $VGNAME > /dev/null
  lvcreate -n ${LVM_USR} -L 20G $VGNAME > /dev/null
  lvcreate -n ${LVM_VAR} -L 30G $VGNAME > /dev/null
  lvcreate -n ${LVM_HOME} -l 100%FREE $VGNAME > /dev/null
}

_create_fs()
{
  echo "create FSs ..."
  mkfs.ext4 ${LVM_DEV}/${LVM_ROOT} -L root > /dev/null
  mkfs.ext4 ${LVM_DEV}/${LVM_USR} -L usr > /dev/null
  mkfs.ext4 ${LVM_DEV}/${LVM_VAR} -L var > /dev/null
  mkfs.ext4 ${LVM_DEV}/${LVM_HOME} -L home > /dev/null
  mkswap -f ${LVM_DEV}/${LVM_SWAP} -L swap > /dev/null
}


_mk_env()
{
  mkdir -p ${LOCAL_ROOTFS}
  rm -rf ${LOCAL_ROOTFS}/lost+found/

  mount ${LVM_DEV}/${LVM_ROOT} ${LOCAL_ROOTFS}
  mkdir -p ${LOCAL_ROOTFS}/{var,usr,home}
}

_mnt_in_env()
{
  mount ${LVM_DEV}/${LVM_VAR} ${LOCAL_ROOTFS}/var/
  mount ${LVM_DEV}/${LVM_USR} ${LOCAL_ROOTFS}/usr/
  mount ${LVM_DEV}/${LVM_HOME} ${LOCAL_ROOTFS}/home/
}

_extr_rootfs()
{
  if [ -z "${TAR_ROOTFS}" ]; then
	  echo "WARNING: Nothing to extract, no creation of rootfs."
	  exit 1
  fi

  echo "extract $TAR_ROOTFS to ${LOCAL_ROOTFS}. This might take a while!!!"
  tar -xjf $TAR_ROOTFS -C ${LOCAL_ROOTFS}/
}

_mnt_in_chroot()
{
  mount -t proc none ${LOCAL_ROOTFS}/proc/
  mount --bind /dev ${LOCAL_ROOTFS}/dev/
  mount --bind /dev/pts ${LOCAL_ROOTFS}/dev/pts
  mount --bind /sys ${LOCAL_ROOTFS}/sys
  cp /etc/resolv.conf ${LOCAL_ROOTFS}/etc/
  
}

_umount_all()
{
  umount ${LOCAL_ROOTFS}/proc
  umount ${LOCAL_ROOTFS}/sys
  umount ${LOCAL_ROOTFS}/dev/pts
  umount ${LOCAL_ROOTFS}/dev
  sleep 1
  umount ${LOCAL_ROOTFS}/home
  umount ${LOCAL_ROOTFS}/var
  umount ${LOCAL_ROOTFS}/usr
  umount ${LOCAL_ROOTFS}/
  sleep 1
#   vgchange -an ${LVM_DEV}/${LVM_ROOT}
#   vgchange -an ${LVM_DEV}/${LVM_USR}
#   vgchange -an ${LVM_DEV}/${LVM_VAR}
#   vgchange -an ${LVM_DEV}/${LVM_HOME}
#   vgchange -an ${LVM_DEV}/${LVM_SWAP}  
#   sleep 1
#   cryptsetup luksClose $CRYPTONAME
  exit 0
}

_mount_all()
{

  if [ -z $MOUNT ]; then
	echo
  else
	cryptsetup luksOpen $DEVICE $CRYPTONAME
	vgscan
	sleep 1
	_mk_env
	_mnt_in_env
	_mnt_in_chroot
	echo "Rock steady, do# chroot ${LOCAL_ROOTFS}"
	exit 0
  fi
}

_write_distro_timezone()
{
	if [ -e /etc/localtime ]; then
		# duplicate host timezone
		cat /etc/localtime > "${LOCAL_ROOTFS}/etc/localtime"
	else
		# otherwise set up UTC
		rm "${LOCAL_ROOTFS}/etc/localtime" > /dev/null 2>&1
		ln -s ../usr/share/zoneinfo/UTC "${LOCAL_ROOTFS}/etc/localtime"
	fi
}


# custom fstab
_create_fstab()
{
	cat <<- EOF > "${LOCAL_ROOTFS}/etc/fstab"
	# required to prevent boot-time error display
	/dev/vg/lvm_root        /               ext4            noatime         0 1
	/dev/vg/lvm_home        /home           ext4            noatime         0 0
	/dev/vg/lvm_var         /var            ext4            noatime         0 0
	/dev/vg/lvm_usr         /usr            ext4            noatime         0 0
	/dev/vg/lvm_swap        none            swap            sw              
#	none    /         none    defaults  0 0
	tmpfs   /dev/shm  tmpfs   defaults  0 0
	tmpfs   /tmp  tmpfs   defaults  0 0
	EOF
	
	mkdir -p ${LOCAL_ROOTFS}/etc/portage/env/
	echo "PORTAGE_TMPDIR=\"/var/tmp/notmpfs\"" >> ${LOCAL_ROOTFS}/etc/portage/env/notmpfs.conf
	mkdir -p ${LOCAL_ROOTFS}/var/tmp/notmpfs
	

	cat <<- EOF > "${LOCAL_ROOTFS}/etc/portage/env/notmpfs.conf"
	app-office/libreoffice notmpfs.conf
	mail-client/mozilla-thunderbird notmpfs.conf
	www-client/chromium notmpfs.conf
	EOF

}



_ch_root_pass()
{
# set_guest_root_password()
# {
# 	[[ -z "$GUESTROOTPASS" ]] && return # pass is empty, abort
# 
# 	echo -n " - setting guest root password.."
# 	echo "root:$GUESTROOTPASS" | chroot "$ROOTFS" chpasswd
# 	echo "done."
# }
  echo "set root password..."
  sed -i /s/root:!:1/root:$6$CvFOBBpb$4VhrxpZ2uWD1HNd8Vpnr1BYzmFpaE8rcJcHou5cfOjAFljQcslrd9JLfEPug.ZD8zEZyJQWdj4kcOirhD6Rg0.:1/g/ ${LOCAL_ROOTFS}/etc/shadow
}

_user_add()
{
  echo "TODO: add user..."
}

_install_x()
{
  echo "install x server ..."
  echo ">=x11-libs/libdrm-2.4.58 libkms" >> ${LOCAL_ROOTFS}/etc/portage/package.use
  echo "=media-libs/mesa-10.2.8 xa" >> ${LOCAL_ROOTFS}/etc/portage/package.use
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge xorg-server" > /dev/null
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge xdm" > /dev/null # maybe not ...? -> lxdm
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge xterm" > /dev/null
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge xsm" > /dev/null
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge twm" > /dev/null
  
  #chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge  lxde-base/lxde-meta" > /dev/null
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge lxdm" > /dev/null
  
  chroot ${LOCAL_ROOTFS} /bin/bash -c "rc-update add xdm default" > /dev/null

  echo ">=x11-libs/pango-1.36.8 X" >> ${LOCAL_ROOTFS}/etc/portage/package.use
  echo "=x11-libs/cairo-1.12.16 X" >> ${LOCAL_ROOTFS}/etc/portage/package.use
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge x11-wm/openbox" > /dev/null
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge obconf" > /dev/null
  chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge x11-misc/fbpanel" > /dev/null
  
  




  
  
}

_gen_locale()
{
  echo "gen locale ..."
  echo "en_US ISO-8859-1" >> ${LOCAL_ROOTFS}/etc/locale.gen
  echo "en_US.UTF-8 UTF-8" >> ${LOCAL_ROOTFS}/etc/locale.gen
  echo "de_DE.UTF-8 UTF-8" >> ${LOCAL_ROOTFS}/etc/locale.gen
  echo "de_DE ISO-8859-1" >> ${LOCAL_ROOTFS}/etc/locale.gen
  echo "de_DE@euro ISO-8859-15" >> ${LOCAL_ROOTFS}/etc/locale.gen
  chroot ${LOCAL_ROOTFS} /bin/bash -c "locale-gen" > /dev/null
}


_set_mak_conf()
{
  echo "set USE Flags..."
  chroot ${LOCAL_ROOTFS} /bin/bash -c  "sed -i 's/USE=\"bindist mmx sse sse2\"/USE=\"bindist mmx sse sse2 qt4 kde alsa cdr\"/g' /etc/portage/make.conf"
}

_mtab()
{
	echo "set mtab ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "ln -sf /proc/self/mounts /etc/mtab"
}

_pre_install_in_chroot()
{
  _mtab
  _gen_locale
  _ch_root_pass
  _user_add
  _create_fstab  
  _write_distro_timezone
  #_set_mak_conf

}

_do_install_in_chroot()
{
  {  
	echo "syncing ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge --sync"
	echo "emerge dhclient ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge net-misc/dhcp"
	echo "emerge pciutils ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge pciutils"
	echo "emerge usbutils ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge usbutils"
	echo "emerge eix ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge eix"
	echo "emerge lvm2 ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge lvm2"
	echo "emerge openssl ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge openssl"
	echo "USE=\"crypt cryptsetup\" emerge genkernel ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "USE=\"crypt cryptsetup\" emerge genkernel"
	echo "emerge iproute2 ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge iproute2" 
	echo "emerge gentoo-sources ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge gentoo-sources" 
	echo "emerge dbus ..."
	chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge dbus" 

	
  } > /dev/null
  
  _install_x
  #app-portage/portage-utils
  #sys-apps/portage
  #app-portage/demerge
  #eclean
  #emerge mkxf86config
  #emerge hwreport
  #emerge lshw
  #emerge hwinfo
  #echo "x11-base/xorg-server udev" >> /etc/portage/package.use
  #emerge --ask xorg-server
  
  #chroot ${LOCAL_ROOTFS} /bin/bash -c "emerge net-wireless/wpa_supplicant"
}



OPTIND=1
while getopts "r:d:umh" opt; do
  case "$opt" in
		r) TAR_ROOTFS="$OPTARG" ;;
		d) DEVICE="$OPTARG" ;;
		h) _help ;;
		u) _umount_all ;;
		m) MOUNT=Yes ;;
		\?) ;;
  esac
done  


if [ -z "${DEVICE}" ]; then
	echo "ERROR: please add device name"
	exit 1
fi

_run_as_root

_mount_all

_cryptsetup

_lvm

_create_fs

_mk_env

_mnt_in_env

_extr_rootfs

_mnt_in_chroot

_pre_install_in_chroot

#_do_install_in_chroot
exit 0