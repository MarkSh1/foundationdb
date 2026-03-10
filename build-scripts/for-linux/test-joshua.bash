#!/bin/bash

# $1 - the path to the correctness archive file, ex. correctness-7.3.49-2.ow.tar.gz
# $2 - number of tests

python3 -m joshua.joshua start --tarball $1 --max-runs $2 && python3 -m joshua.joshua tail | tee /tmp/joshua_output.txt

if grep -q 'Ok="0"' /tmp/joshua_output.txt; then
  echo >&2 "Test failed."
  exit 1
fi