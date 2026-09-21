#!/bin/sh

#deal with expanding the SD card partition for the initial image shipped that is only small 
# /root/resize_sdpublic.sh expand

FW_DIR=/root/Exec
DEFAULT_APP=/root/NextGen

# `ls -r` keeps the existing highest-version-first behaviour,
# assuming versions are zero-padded: V001, V002, V010, etc.
for i in $(ls -r1 "$FW_DIR"/NgSound_V* 2>/dev/null); do
        [ -f "$i" ] || continue
        [ -x "$i" ] || continue

        md5="${i##*_}"

        echo "Checking $i"

        if printf '%s  %s\n' "$md5" "$i" | md5sum -s -c -; then
                echo "Launching $i"
                exec "$i"
        fi
done

echo "No valid NgSound firmware found; launching $DEFAULT_APP"
exec "$DEFAULT_APP"

