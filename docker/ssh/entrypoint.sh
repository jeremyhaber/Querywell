#!/bin/sh
# Install the mounted authorized_keys with the ownership/permissions sshd's StrictModes requires.
set -e
mkdir -p /home/querywell/.ssh
if [ -f /keys/authorized_keys ]; then cp /keys/authorized_keys /home/querywell/.ssh/authorized_keys; fi
touch /home/querywell/.ssh/authorized_keys
chown -R querywell:querywell /home/querywell/.ssh
chmod 700 /home/querywell/.ssh && chmod 600 /home/querywell/.ssh/authorized_keys
exec /usr/sbin/sshd -D -e
