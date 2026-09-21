#!/bin/sh
#
# S00NextGen starts the application before the normal rcS services.  Publish a
# simple milestone after udev and module loading have completed so the
# application can keep its splash visible without racing hardware init.
#
case "$1" in
    start)
        : > /run/nextgen-boot-prereqs
        ;;
    stop)
        rm -f /run/nextgen-boot-prereqs
        ;;
esac
