#!/bin/bash
host=212.58.244.56
size=1272
while ping -s $size -c1 -M do $host; do
  ((size+=4))
done
echo "Max MTU size: $((size-4+28))"

