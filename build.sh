#!/bin/sh
set ${SET_X:+-x} -eou pipefail

### Install packages

# Packages can be installed from any enabled yum repo on the image.
# RPMfusion repos are available by default in ublue main images
# List of rpmfusion packages can be found here:
# https://mirrors.rpmfusion.org/mirrorlist?path=free/fedora/updates/39/x86_64/repoview/index.html&protocol=https&redirect=1

# this installs and removes/replaces all required packages
echo "::group::Install kernel and akmods as needed"
/ctx/kernel.sh
echo "::endgroup::"

echo "::group::Install packages"
/ctx/packages.sh
echo "::endgroup::"

echo "::group::Customization"
/ctx/customization.sh
echo "::endgroup::"

echo "::group::Generate initramfs"
/ctx/initramfs.sh
echo "::endgroup::"

echo "::group::Clean up"
/ctx/cleanup.sh
echo "::endgroup::"
