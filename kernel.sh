#!/bin/bash
set ${SET_X:+-x} -eou pipefail

installed=$(rpm -q --queryformat '%{VERSION}-%{RELEASE}.%{ARCH}' kernel)
wanted=$KERNEL

if [[ $installed == $wanted ]]; then
  echo "Nothing to do"
else
  echo "Change kernel - $installed to $wanted"
  kernel_packages=$(rpm -qa 'kernel*')
  for pkg in $kernel_packages; do
    rpm --erase $pkg --nodeps
  done
  kernel_packages=$(echo $kernel_packages | sed "s/${installed}/${wanted}/g")
  dnf install -y $kernel_packages
fi
