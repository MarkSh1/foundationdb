#!/bin/bash

# $1 - the path to the correctness archive file, ex. correctness-7.3.49-2.ow.tar.gz
# $2 - number of tests

python3 -m joshua.joshua start --tarball $1 --max-runs $2 && \
  python3 -m joshua.joshua tail | python3 -c "
import sys, re, io
sys.stdout = io.TextIOWrapper(sys.stdout.buffer, line_buffering=True)
failed = False
for line in sys.stdin:
    m = re.search(r'TestFile=\"([^\"]+)\".*?Ok=\"(\d+)\"', line)
    if m:
        print(f'TestFile=\"{m.group(1)}\" Ok=\"{m.group(2)}\"')
        if m.group(2) == '0':
            failed = True
    else:
        sys.stdout.write(line)
sys.exit(1 if failed else 0)
"
