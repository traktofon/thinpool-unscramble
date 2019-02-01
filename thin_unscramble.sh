#!/bin/bash

set -e

function usage () {
   cat <<EOF
Usage: $0 <tpool> <tpool_rmap>
   where <tpool> is an image of the thin pool's data portion, and
   <tpool_rmap> is the reverse mapping obtained from the thin pool's
   metadata with the 'thin_rmap' tool.
EOF
   exit 1
}

PREFIX='test'

[ -z "$1" -o -z "$2" ] && usage;
TPOOLFILE="$1"
RMAPFILE="$2"

# Lines in the tpool_rmap are like:
# data 1..2 -> thin(13) 262143..262144

RMAPLINES=$(cat "$RMAPFILE" | wc -l)
RMAPCOUNT=0
while read DATA DATARANGE ARROW THIN THINRANGE; do
   DATALO=${DATARANGE%..*}
   DATAHI=${DATARANGE#*..}
   THINLO=${THINRANGE%..*}
   THINHI=${THINRANGE#*..}
   DATALEN=$[DATAHI-DATALO]
   THINLEN=$[THINHI-THINLO]
   if [ $DATALEN -ne $THINLEN ]; then
      echo "ERROR: different length in chunk '$DATA $DATARANGE $ARROW $THIN $THINRANGE'" >&2
      exit 1
   fi
   TMP=${THIN#*(}
   THINID=${TMP%)}
   dd if="$TPOOLFILE" of="$PREFIX$THINID.dat" bs=64k skip=$DATALO seek=$THINLO count=$DATALEN conv=notrunc status=none
   RMAPCOUNT=$[RMAPCOUNT+1]
   echo -ne "processed $RMAPCOUNT / $RMAPLINES \r" >&2
done < "$RMAPFILE"
echo >&2

