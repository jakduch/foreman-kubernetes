#!/bin/sh
set -eu

authorized_key=/keys/authorized_key

if [ ! -s "${authorized_key}" ]; then
  echo "SSH target public key is missing: ${authorized_key}" >&2
  exit 1
fi

install -d -m 0700 -o foreman -g foreman /home/foreman/.ssh
install -m 0600 -o foreman -g foreman "${authorized_key}" /home/foreman/.ssh/authorized_keys
ssh-keygen -A

exec /usr/sbin/sshd -D -e
