#!/bin/sh
while :; do
  printf 'sample %s ' "$(date +%s)"
  awk '/^MemAvailable:/{a=$2}/^AnonPages:/{b=$2}/^MemTotal:/{t=$2}END{printf "total_kib=%s available_kib=%s anon_kib=%s\n",t,a,b}' /proc/meminfo
  for p in $(pidof nginx 2>/dev/null);do
    if [ -r "/proc/$p/smaps_rollup" ];then
      awk -v p="$p" '/^Rss:/{r=$2}/^Pss:/{s=$2}/^Private_Clean:/{c=$2}/^Private_Dirty:/{d=$2}END{printf "nginx pid=%s rss_kib=%s pss_kib=%s private_kib=%s\n",p,r,s,c+d}' "/proc/$p/smaps_rollup" 2>/dev/null
    fi
  done
  sleep 5
done
