#!/bin/sh
# Used to create the dfsg .orig.tar from the upstream source
if [ -z "$1" -o -z "$2" ]; then
	echo "Usage: $0 UPSTREAMTARBALL UPSTREAMVERSION"
	exit 1
fi

UPSTREAMTARBALL=$1
UPSTREAMVERSION=$2

mk-origtargz \
	--exclude-file html/hints/solaris-dosynctodr.html \
	--exclude-file libntp/adjtime.c \
	--exclude-file include/adjtime.h \
	--exclude-file include/timepps-SCO.h \
	--exclude-file include/timepps-Solaris.h \
	--exclude-file include/timepps-SunOS.h \
	--exclude-file ports/winnt/libntp/messages.mc \
	--exclude-file ports/winnt/include/hopf_PCI_io.h \
	--exclude-file scripts/monitoring/lr.pl \
	--exclude-file scripts/monitoring/ntp.pl \
	--exclude-file scripts/monitoring/ntploopstat \
	--exclude-file scripts/monitoring/ntploopwatch \
	--exclude-file scripts/monitoring/ntptrap \
	--exclude-file scripts/ntpver.in \
	--exclude-file libparse/clk_wharton.c \
	--package ntp \
	--repack \
	--repack-suffix +dfsg \
	--compression xz \
	--version $2 \
	$1
