#!/bin/bash
perf report -i /tmp/ippm.perf --no-children --stdio -G -S '$s20FoundationEssentials4DataV8IteratorV4nexts5UInt8VSgyF' 2>/dev/null | grep -v "^#\|^$" | grep -oE '\$s[A-Za-z0-9_]+|[a-z_]+\(' | grep -v "FoundationEssentials4Data" | awk '!seen[$0]++' | head -25
