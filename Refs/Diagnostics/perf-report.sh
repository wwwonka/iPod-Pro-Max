#!/bin/bash
echo "== by library"; perf report -i /tmp/ippm.perf --no-children --sort dso --stdio -g none 2>/dev/null | grep "%" | head -8
echo "== top symbols"; perf report -i /tmp/ippm.perf --no-children --sort sym --stdio -g none 2>/dev/null | grep "%" | head -25
echo "== inclusive app/SwiftCrossUI frames"; perf report -i /tmp/ippm.perf --children --sort sym --stdio -g none 2>/dev/null | grep "%" | grep -iE "swift|\\$s|gtk_widget|css|pango|measure|allocate|snapshot" | head -40
