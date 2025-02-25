#!/bin/sh

set -ouex pipefail

cd /tmp

wget https://github.com/slaclau/yaru-extra-icons/archive/master.tar.gz
tar xf master.tar.gz
cp -r yaru-extra-icons-master/Custom /usr/share/icons/

cp /ctx/data/emblem-warning.png /usr/share/plymouth/themes/spinner/
