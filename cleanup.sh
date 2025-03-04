#!/bin/sh
set ${SET_X:+-x} -eou pipefail

if [[ $FEDORA_MAJOR_VERSION -gt 40 ]]; then
  dnf5 clean all
fi

rm -rf /tmp/*
rm -rf /var/*
mkdir -p /tmp
mkdir -p /var/tmp
chmod -R 1777 /var/tmp

ostree container commit
