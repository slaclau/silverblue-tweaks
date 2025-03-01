#!/bin/sh
dnf5 clean all

rm -rf /tmp/*
rm -rf /var/*
mkdir -p /tmp
mkdir -p /var/tmp
chmod -R 1777 /var/tmp

ostree container commit
