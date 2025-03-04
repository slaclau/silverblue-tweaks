#!/bin/bash
set ${SET_X:+-x} -eou pipefail

installed=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)
wanted=$KERNEL

if [[ $installed == $wanted ]]; then
  echo "Nothing to do"
else
  echo "TBC: change kernel - $installed to $wanted"
fi
