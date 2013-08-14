#!/bin/bash

FLAVOR=${FLAVOR:-FULL}
# options are:
#   FULL - chef qcow, images, and opscode installer backed into the iso
#   MINIMAL - no extra things are baked into the iso

[[ $(uname -s) = "Darwin" ]] && PLATFORM="osx" || PLATFORM="linux"

# make sure we have dependencies
[[ "$PLATFORM" = "osx" ]] && BINARIES="mkisofs bsdtar curl md5 cpio gunzip" || BINARIES="genisoimage bsdtar curl md5sum cpio gunzip"

for binary in $BINARIES; do
    hash $binary 2>/dev/null || { echo >&2 "ERROR: $binary not found. Aborting."; exit 1; }
done

set -o nounset
set -o errexit
#set -o xtrace

# Configurations
if [ "${RELEASE:-}" == "" ]; then
    MINORVER=$(git rev-parse HEAD | cut -b -6)
else
    MINORVER=${RELEASE}
fi

MAJORVER="4.6.0"
CODENAME="orb"

if ! git diff-index --quiet HEAD; then
    if [ "${RELEASE:-}" != "" ]; then
        echo "Can't release with a dirty git."
        exit 1
    fi
    MINORVER="local"
fi

cat > version.cfg <<EOF
major_version=${MAJORVER}
minor_version=${MINORVER}
codename=${CODENAME}
EOF

PRIDE="${CODENAME}-v${MAJORVER}-${MINORVER}"
UDEB_NAME="rpcs-pre rpcs-post kvmcheck proxy-check eula"

ISO_URL="http://releases.ubuntu.com/precise/ubuntu-12.04.2-server-amd64.iso"
ISO_MD5="af5f788aee1b32c4b2634734309cc9e9"
ISO_CUSTOM="rpcs-pridery.iso"
CIRROS_IMAGE_NAME="cirros-0.3.0-x86_64-uec.tar.gz"
CIRROS_URL="https://launchpadlibrarian.net/83305869/${CIRROS_IMAGE_NAME}"
PRECISE_IMAGE_NAME="precise-server-cloudimg-amd64.tar.gz"
PRECISE_URL="http://cloud-images.ubuntu.com/precise/current/${PRECISE_IMAGE_NAME}"
CHEF_SERVER_DEB_URL="http://www.opscode.com/chef/download-server?p=ubuntu&pv=12.04&m=x86_64"
CHEF_SERVER_DEB_NAME="chef-server.deb"

# location, location, location
FOLDER_BASE=$(pwd)
FOLDER_ISO="${FOLDER_BASE}/iso"
FOLDER_RESOURCES="${FOLDER_BASE}/resources"
FOLDER_BUILD="${FOLDER_BASE}/build"
FOLDER_ISO_CUSTOM="${FOLDER_BUILD}/iso/custom"
FOLDER_ISO_CUSTOM_RPCS="${FOLDER_ISO_CUSTOM}/opt/rpcs"
FOLDER_ISO_INITRD="${FOLDER_BUILD}/iso/initrd"

# start with a clean slate
if [ -d "$FOLDER_BUILD" ]; then
  echo "Cleaning build directory ..."
  chmod -R u+w "$FOLDER_BUILD"
  rm -rf "$FOLDER_BUILD"
  mkdir -p "$FOLDER_BUILD"
fi

# remove previous ISO
if [ -e "${FOLDER_ISO}/$ISO_CUSTOM.old" ]; then
  echo "Removing previous $ISO_CUSTOM.old ..."
  rm -f "${FOLDER_ISO}/$ISO_CUSTOM.old"
fi
if [ -e "${FOLDER_ISO}/$ISO_CUSTOM" ]; then
  echo "Moving $ISO_CUSTOM to $ISO_CUSTOM.old ..."
  mv -f "${FOLDER_ISO}/$ISO_CUSTOM" "${FOLDER_ISO}/$ISO_CUSTOM.old"
fi

mkdir -p "$FOLDER_ISO"
mkdir -p "$FOLDER_BUILD"
mkdir -p "$FOLDER_ISO_CUSTOM"
mkdir -p "$FOLDER_ISO_INITRD"

ISO_FILENAME="${FOLDER_RESOURCES}/$(basename $ISO_URL)"
PRECISE_FILENAME="${FOLDER_RESOURCES}/${PRECISE_IMAGE_NAME}"
CIRROS_FILENAME="${FOLDER_RESOURCES}/${CIRROS_IMAGE_NAME}"
CHEF_SERVER_DEB_FILENAME="${FOLDER_RESOURCES}/${CHEF_SERVER_DEB_NAME}"

download(){
  URL="$1"
  FILENAME="$2"
  if [ ! -e "$FILENAME" ] && [ "${FLAVOR}" = "FULL" ]; then
    echo "Downloading $FILENAME ..."
    curl --output "${FILENAME}" -L "${URL}"
  fi
}

download "$PRECISE_URL" "$PRECISE_FILENAME"&
download "$CIRROS_URL" "$CIRROS_FILENAME"&
download "$CHEF_SERVER_DEB_URL" "$CHEF_SERVER_DEB_FILENAME"&
wait

# download the installation disk if we haven't already or it is corrupted somehow
if [ -e "$ISO_FILENAME" ]; then
  if [[ "$PLATFORM" = "osx" && $(md5 -q "$ISO_FILENAME") != "$ISO_MD5" ]] || [[ "$PLATFORM" != "osx" && $ISO_MD5 != `md5sum $ISO_FILENAME | cut -d ' ' -f1` ]]; then
    echo "Removing bad iso"
    rm "$ISO_FILENAME"
  fi
fi  
if [ ! -e "$ISO_FILENAME" ]; then
  echo "Downloading $(basename $ISO_URL) ..."
  curl --output "$ISO_FILENAME" -L "$ISO_URL"
  $([[ "$PLATFORM" = "osx" ]] && [[ $(md5 -q "$ISO_FILENAME") = "$ISO_MD5" ]] || md5sum -c --status <(echo "$ISO_MD5  $ISO_FILENAME")) || { echo >&2 "ERROR: MD5 does not match. Aborting."; exit 1; }
fi

# untar that sucker
echo "Untarring downloaded ISO ..."
$([[ "$PLATFORM" = "osx" ]] && echo "/usr/local/bin/bsdtar" || echo "bsdtar") -C "$FOLDER_ISO_CUSTOM" -xf "$ISO_FILENAME"

# move initrd
chmod u+w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz"
mv "${FOLDER_ISO_CUSTOM}/install/initrd.gz" "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"

# customize initrd
echo "Customizing new initrd ..."
  (
  cd "$FOLDER_ISO_INITRD"
  gunzip -c "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org" | cpio -id &>/dev/null || :

  cp "${FOLDER_BASE}/preseed.cfg" "${FOLDER_ISO_INITRD}/preseed.cfg"
  cp "${FOLDER_BASE}/rpcs/rpcs-functions" "$FOLDER_ISO_INITRD/var/lib/dpkg/info/"

  for udeb in $UDEB_NAME; do
      cp "${FOLDER_BASE}/rpcs/udeb-templates/${udeb}/postinst" "${FOLDER_ISO_INITRD}/var/lib/dpkg/info/${udeb}.postinst"
      chmod +x "${FOLDER_ISO_INITRD}/var/lib/dpkg/info/${udeb}.postinst"
      cp "${FOLDER_BASE}/rpcs/udeb-templates/${udeb}/templates" "${FOLDER_ISO_INITRD}/var/lib/dpkg/info/${udeb}.templates"
      cat "${FOLDER_BASE}/rpcs/udeb-templates/${udeb}/status" >> "${FOLDER_ISO_INITRD}/var/lib/dpkg/status"
  done;
  find . | cpio --create --format='newc' 2>/dev/null | gzip  > "${FOLDER_ISO_CUSTOM}/install/initrd.gz"
  )

# clean up
rm "${FOLDER_ISO_CUSTOM}/install/initrd.gz.org"
chmod u-w "${FOLDER_ISO_CUSTOM}/install" "${FOLDER_ISO_CUSTOM}/install/initrd.gz"

# replace isolinux configuration
echo "Replacing isolinux config ..."
chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
rm "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
cp "${FOLDER_BASE}/isolinux.cfg" "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.cfg"
chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/isolinux.bin"

# add BRANDING
echo "Adding ISO Branding..."
chmod u+w "${FOLDER_ISO_CUSTOM}/isolinux/splash.pcx" "${FOLDER_ISO_CUSTOM}/isolinux/splash.png"
cp "${FOLDER_BASE}/rpcs/images/private-cloud-openstack-logo-640x480.pcx" "${FOLDER_ISO_CUSTOM}/isolinux/splash.pcx"
cp "${FOLDER_BASE}/rpcs/images/private-cloud-openstack-logo-640x480.png" "${FOLDER_ISO_CUSTOM}/isolinux/splash.png"

# create the custom directory"
mkdir -p "$FOLDER_ISO_CUSTOM_RPCS"

mkdir -p "$FOLDER_ISO_CUSTOM_RPCS/resources"
# move over the chef-server.qcow2

if [ -e "${PRECISE_FILENAME}" ] && [ "${FLAVOR}" = "FULL" ]; then
    echo "Embedding the precise image ..."
    cp "${PRECISE_FILENAME}" "${FOLDER_ISO_CUSTOM_RPCS}/resources/"
    echo "precise_url=\"file:///opt/rpcs/precise-server-cloudimg-amd64.tar.gz\"" >> ${FOLDER_ISO_CUSTOM_RPCS}/rpcs.cfg
else
    echo "precise_url=\"$PRECISE_URL\"" >> ${FOLDER_ISO_CUSTOM_RPCS}/rpcs.cfg
fi

if [ -e "${CIRROS_FILENAME}" ] && [ "${FLAVOR}" = "FULL" ]; then
    echo "Embedding the cirros image ..."
    cp "${CIRROS_FILENAME}" "${FOLDER_ISO_CUSTOM_RPCS}/resources/"
    echo "cirros_url=\"file:///opt/rpcs/cirros-0.3.0-x86_64-uec.tar.gz\"" >> ${FOLDER_ISO_CUSTOM_RPCS}/rpcs.cfg
else
    echo "cirros_url=\"$CIRROS_URL\"" >> ${FOLDER_ISO_CUSTOM_RPCS}/rpcs.cfg
fi

if [ -e ${CHEF_SERVER_DEB_FILENAME} ] && [ "${FLAVOR}" == "FULL" ]; then
  echo "Embedding chef server deb."
  cp "${CHEF_SERVER_DEB_FILENAME}" "${FOLDER_ISO_CUSTOM_RPCS}/resources/"
fi

# add some files
echo "Add extra files ..."
chmod u+w "$FOLDER_ISO_CUSTOM"
cp "${FOLDER_BASE}/rpcs/functions.sh" "$FOLDER_ISO_CUSTOM_RPCS/"
cp "${FOLDER_BASE}/rpcs/late_command.sh" "$FOLDER_ISO_CUSTOM_RPCS/"
cp "${FOLDER_BASE}/rpcs/post-install.sh" "$FOLDER_ISO_CUSTOM_RPCS/post-install.sh"
cp "${FOLDER_BASE}/rpcs/status.sh" "$FOLDER_ISO_CUSTOM_RPCS/"
cp "${FOLDER_BASE}/rpcs/status.rb" "$FOLDER_ISO_CUSTOM_RPCS/"
cp "${FOLDER_BASE}/rpcs/amqping.py" "$FOLDER_ISO_CUSTOM_RPCS/"
cp "${FOLDER_BASE}/version.cfg" "$FOLDER_ISO_CUSTOM_RPCS/"
cp "${FOLDER_BASE}/rpcs/RPCS_EULA.txt" "$FOLDER_ISO_CUSTOM_RPCS/"

echo "Adding boot branding..."
chmod u+w "$FOLDER_ISO_CUSTOM"
mkdir -p "$FOLDER_ISO_CUSTOM_RPCS/themes/"
cp -R "${FOLDER_BASE}/rpcs/themes/rpcs" "$FOLDER_ISO_CUSTOM_RPCS/themes/"
cp -R "${FOLDER_BASE}/rpcs/themes/rpcs-text" "$FOLDER_ISO_CUSTOM_RPCS/themes/"

# generate yourself an ISO
echo "Generating custom ISO ..."
$([[ "$PLATFORM" = "linux" ]] && echo "genisoimage" || echo "mkisofs") -r -V "Custom RPCS CD" \
  -cache-inodes -quiet \
  -J -l -b isolinux/isolinux.bin \
  -c isolinux/boot.cat -no-emul-boot \
  -boot-load-size 4 -boot-info-table \
  -o "${FOLDER_ISO}/$ISO_CUSTOM" "$FOLDER_ISO_CUSTOM"

# Removing all previous release symlinks, creating new symlink with release naming
echo "Removing previous symlinks, creating new"

# find where symlinks are pointing, so we can roll them
CURRENT_ISO=""
OLD_ISO=""
NEW_ISO="${FOLDER_ISO}/${PRIDE}-${FLAVOR}.iso"

if [ -L "${FOLDER_ISO}/rpcs-${FLAVOR}.iso" ]; then
    CURRENT_ISO=$(readlink "${FOLDER_ISO}/rpcs-${FLAVOR}.iso")
fi

if [ -L "${FOLDER_ISO}/rpcs-${FLAVOR}.iso.old" ]; then
    OLD_ISO=$(readlink "${FOLDER_ISO}/rpcs-${FLAVOR}.iso.old")
fi

echo "Rolled new iso.. rotating symlinks"

# remove symlinks
rm -f "${FOLDER_ISO}/rpcs-${FLAVOR}.iso"
rm -f "${FOLDER_ISO}/rpcs-${FLAVOR}.iso.old"

# remove old iso
[ -s "${OLD_ISO}" ] && rm "${OLD_ISO}"

# before moving new iso into place, check that the last one doesn't already
# exist with the same name - if so move it to .old
if [ "${CURRENT_ISO}" == "${NEW_ISO}" ]; then
    mv "${CURRENT_ISO}" "${CURRENT_ISO}.old"
    CURRENT_ISO="${CURRENT_ISO}.old"
fi

# move the new ISO into place
mv -f "${FOLDER_ISO}/${ISO_CUSTOM}" "${NEW_ISO}"

# link to new
ln -s "$NEW_ISO" "${FOLDER_ISO}/rpcs-${FLAVOR}.iso"

echo "Newly rolled iso (${PRIDE}-${FLAVOR}.iso) can be found at ${FOLDER_ISO}/rpcs-${FLAVOR}.iso"
