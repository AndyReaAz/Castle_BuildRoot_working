#!/bin/sh
#
# S00NextGen starts the application before the normal rcS services.  Publish a
# milestone immediately before the historical S55NextGen point so the
# application can display its splash early without racing services that used
# to be guaranteed ready before Application started.
#
case "$1" in
    start)
        : > /run/nextgen-boot-prereqs
        ;;
    stop)
        rm -f /run/nextgen-boot-prereqs
        ;;
esac
