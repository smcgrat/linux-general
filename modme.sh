#!/bin/bash

dir=`pwd`
date=`date '+%y-%m-%d-%H.%M.%S'`
record=~/.modme.log
note=$@

echo "recording what modules you have setup to standard output & $record"

(
echo "============================================"
echo "modules loaded in $dir at $date:"
module list
if [ -n "$note" ]; then
  echo $note
fi
) 2>&1 | tee -a $record

exit 0
