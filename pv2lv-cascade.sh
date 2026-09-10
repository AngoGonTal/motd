#!/usr/bin/env bash
export LC_ALL=C

blk_cache() {
  local p=$1 w
  w=$(cat "/sys/class/block/$p/queue/write_cache" 2>/dev/null || :)
  case "$w" in
    *"write back"*)    echo WB ;;
    *"write through"*) echo WT ;;
    *)                 echo NA ;;
  esac
}

printf 'BLOCK DEVICES  (CACHE: WB=write-back, WT=write-through)\n'
printf '%-20s %6s %-5s %-5s %s\n' DEVICE SIZE CACHE MEDIA SERIAL

while read -r d sz ty rot; do
  [[ $ty == disk || $ty == part ]] || continue

  p=$(lsblk -ndo PKNAME "$d" 2>/dev/null)
  [[ -n $p ]] || p=${d#/dev/}
  p=${p##*/}

  s=$(lsblk -dn -o SERIAL "/dev/$p" 2>/dev/null | xargs)
  c=$(blk_cache "$p")

  case $rot in
    0) m=FLASH ;;
    1) m=HDD ;;
    *) m='?' ;;
  esac

  printf '%-20s %6s %-5s %-5s %s\n' \
    "$d" "$sz" "$c" "$m" "${s:--}" | fold -w 80
done < <(lsblk -nrpo NAME,SIZE,TYPE,ROTA)


printf '\nLVM LOGICAL VOLUMES\n'
printf '%-27s %7s %-10s %-10s %s\n' \
  LV SIZE TYPE RAID 'PVs(/dev/)'

lvgraph=$(lvs -a --segments --noheadings --separator '|' \
  -o vg_name,lv_name,devices 2>/dev/null || :)

pvs_for_lv() {
  awk -F'|' -v V="$1" -v L="$2" '
  function clean(x) {
    gsub(/^[ \t]+|[ \t]+$/, "", x)
    return x
  }
  function add(x) {
    if (!have[x]++) out[++n]=x
  }
  function walk(x, s,a,i,e,k,c) {
    k=V SUBSEP x
    if (seen[k]++ || !(k in dev)) return

    s=dev[k]
    c=split(s,a,",")

    for (i=1; i<=c; i++) {
      e=clean(a[i])
      sub(/\([0-9]+\)$/, "", e)
      gsub(/^\[|\]$/, "", e)

      if (e ~ /^\/dev\//) {
        sub(/^\/dev\//, "", e)
        add(e)
      } else if ((V SUBSEP e) in dev) {
        walk(e)
      }
    }
  }

  {
    v=clean($1)
    nme=clean($2)
    k=v SUBSEP nme

    if (dev[k] != "")
      dev[k]=dev[k] "," $3
    else
      dev[k]=$3
  }

  END {
    walk(L)
    for (i=1; i<=n; i++)
      printf "%s%s", i==1 ? "" : ",", out[i]
  }' <<<"$lvgraph"
}

while IFS='|' read -r vg lv sz ty health cp; do
  for v in vg lv sz ty health cp; do
    printf -v "$v" '%s' "${!v//[[:space:]]/}"
  done

  [[ -n $lv ]] || continue
  raid=-

  if [[ $ty == raid* || $ty == mirror ]]; then
    if [[ -n $health ]]; then
      raid=$health
    elif [[ -n $cp && $cp != 100* ]]; then
      raid="sync${cp%%.*}%"
    else
      raid=ok
    fi
  fi

  pvs=$(pvs_for_lv "$vg" "$lv")
  [[ -n $pvs ]] || pvs=-

  printf '%-27s %7s %-10s %-10s %s\n' \
    "$vg/$lv" "$sz" "$ty" "$raid" "$pvs" | fold -w 80
done < <(
  lvs --noheadings --separator '|' \
    -o vg_name,lv_name,lv_size,segtype,lv_health_status,copy_percent \
    2>/dev/null
)


printf '\nBTRFS FILESYSTEMS  (one row per FS UUID)\n'
printf '%-18s %7s %-19s %s\n' \
  FS SIZE PROFILE 'DEVICES(/dev/)'

declare -A seenfs

while read -r uuid mnt; do
  [[ -n $uuid && -z ${seenfs[$uuid]+x} ]] || continue
  seenfs[$uuid]=1

  label=$(findmnt -n -o LABEL "$mnt" 2>/dev/null | head -1)
  [[ -n $label ]] || label=${uuid:0:8}

  bytes=$(df -B1 --output=size "$mnt" 2>/dev/null | tail -1 | xargs)

  if [[ $bytes =~ ^[0-9]+$ ]]; then
    sz=$(numfmt --to=iec --suffix=B "$bytes")
  else
    sz='?'
  fi

  bdf=$(btrfs filesystem df "$mnt" 2>/dev/null || :)

  dp=$(sed -n 's/^Data, \([^:]*\):.*/\1/p' <<<"$bdf" |
    tr A-Z a-z | paste -sd+ -)

  mp=$(sed -n 's/^Metadata, \([^:]*\):.*/\1/p' <<<"$bdf" |
    tr A-Z a-z | paste -sd+ -)

  [[ -n $dp ]] || dp='?'
  [[ -n $mp ]] || mp='?'

  if [[ $dp == "$mp" ]]; then
    prof=$dp
  else
    prof="D:$dp/M:$mp"
  fi

  show=$(btrfs filesystem show "$mnt" 2>/dev/null || :)
  devs=$(sed -n 's/.* path \/dev\///p' <<<"$show" | paste -sd, -)
  [[ -n $devs ]] || devs=-

  printf '%-18s %7s %-19s %s\n' \
    "$label" "$sz" "$prof" "$devs" | fold -w 80
done < <(findmnt -rn -t btrfs -o UUID,TARGET)
