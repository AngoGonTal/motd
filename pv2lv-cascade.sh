#!/usr/bin/env bash
set -u
export LC_ALL=C

# ---------------------------------------------------------------------------
# Rechte prüfen
# ---------------------------------------------------------------------------

if (( EUID != 0 )); then
  echo "ERROR: Dieses Skript muss als root ausgeführt werden." >&2
  echo "       Bitte verwenden: sudo $0" >&2
  exit 1
fi


# ---------------------------------------------------------------------------
# Block devices
# ---------------------------------------------------------------------------

printf 'BLOCK DEVICES\n'
printf '%-20s %6s %-5s %s\n' \
  DEVICE SIZE MEDIA SERIAL

while read -r d sz ty rot; do
  [[ $ty == disk || $ty == part ]] || continue

  p=$(lsblk -ndo PKNAME "$d" 2>/dev/null)
  [[ -n $p ]] || p=${d#/dev/}
  p=${p##*/}

  s=$(lsblk -dn -o SERIAL "/dev/$p" 2>/dev/null | xargs)

  case $rot in
    0) m=FLASH ;;
    1) m=HDD ;;
    *) m='?' ;;
  esac

  printf '%-20s %6s %-5s %s\n' \
    "$d" "$sz" "$m" "${s:--}" |
    fold -w 80

done < <(
  lsblk -nrpo NAME,SIZE,TYPE,ROTA
)


# ---------------------------------------------------------------------------
# LVM
# ---------------------------------------------------------------------------

printf '\nLVM LOGICAL VOLUMES\n'
printf '%-30s %7s %-9s %-8s %s\n' \
  LV SIZE TYPE RAID 'PVs(/dev/)'

#
# Segment-Graph inklusive interner RAID-LVs.
# Dieser Report darf segmentbezogen sein, weil er nur intern verwendet wird.
#
lvgraph=$(
  lvs -a --segments --noheadings --separator '|' \
    -o vg_name,lv_name,devices 2>/dev/null || :
)

#
# Rekursive Auflösung:
#
# sichtbares LV
#   -> internes rimage/rmeta/etc.
#   -> echtes /dev/sdX-PV
#
pvs_for_lv() {
  awk -F'|' -v V="$1" -v L="$2" '

  function clean(x) {
    gsub(/^[ \t]+|[ \t]+$/, "", x)
    return x
  }

  function add(x) {
    if (!have[x]++)
      out[++n]=x
  }

  function walk(x, s,a,i,e,k,c) {
    k=V SUBSEP x

    if (seen[k]++ || !(k in dev))
      return

    s=dev[k]
    c=split(s,a,",")

    for (i=1; i<=c; i++) {
      e=clean(a[i])

      sub(/\([0-9]+\)$/, "", e)
      gsub(/^\[/, "", e)
      gsub(/\]$/, "", e)

      if (e ~ /^\/dev\//) {
        sub(/^\/dev\//, "", e)
        add(e)
      } else if ((V SUBSEP e) in dev) {
        walk(e)
      }
    }
  }

  {
    vg=clean($1)
    lv=clean($2)

    gsub(/^\[/, "", lv)
    gsub(/\]$/, "", lv)

    k=vg SUBSEP lv

    if (dev[k] != "")
      dev[k]=dev[k] "," $3
    else
      dev[k]=$3
  }

  END {
    walk(L)

    for (i=1; i<=n; i++)
      printf "%s%s", i == 1 ? "" : ",", out[i]
  }
  ' <<<"$lvgraph"
}

#
# Alle real vorkommenden PVs ermitteln.
#
# Daraus entsteht eine feste horizontale Position:
#
# sda sdb sdc sdd sde ...
#
mapfile -t pv_columns < <(
  awk -F'|' '
  {
    n=split($3,a,",")

    for (i=1; i<=n; i++) {
      x=a[i]

      gsub(/^[ \t]+|[ \t]+$/, "", x)
      sub(/\([0-9]+\)$/, "", x)
      gsub(/^\[/, "", x)
      gsub(/\]$/, "", x)

      if (x ~ /^\/dev\//) {
        sub(/^\/dev\//, "", x)
        print x
      }
    }
  }' <<<"$lvgraph" |
    sort -Vu
)

#
# PV-Liste in eine positionsfeste Matrix umwandeln.
#
# Beispiel:
#
# sda,sdb,    sdd,sde
# sda,sdb,sdc,sdd,sde
# sda,            sde
# sda
#         sdc
#
format_pvs() {
  local csv=$1 p col out="" i j last=-1 comma
  local -a selected=()
  local -A member=()

  [[ -n $csv && $csv != "-" ]] || {
    printf '-'
    return
  }

  IFS=',' read -ra selected <<<"$csv"

  for p in "${selected[@]}"; do
    member["$p"]=1
  done

  for ((i=0; i<${#pv_columns[@]}; i++)); do
    if [[ ${member[${pv_columns[i]}]+x} ]]; then
      last=$i
    fi
  done

  (( last >= 0 )) || {
    printf '-'
    return
  }

  for ((i=0; i<=last; i++)); do
    col=${pv_columns[i]}

    if [[ ${member[$col]+x} ]]; then
      comma=""

      for ((j=i+1; j<=last; j++)); do
        if [[ ${member[${pv_columns[j]}]+x} ]]; then
          comma=","
          break
        fi
      done

      printf -v out '%s%-4s' "$out" "${col}${comma}"
    else
      printf -v out '%s%-4s' "$out" ""
    fi
  done

  printf '%s' "$out"
}

#
# lv_layout ist LV-bezogen und verhindert Mehrfachausgaben durch Segmente.
#
while IFS='|' read -r vg lv sz layout health cp; do
  vg=$(xargs <<<"$vg")
  lv=$(xargs <<<"$lv")
  sz=$(xargs <<<"$sz")
  layout=$(xargs <<<"$layout")
  health=$(xargs <<<"$health")
  cp=$(xargs <<<"$cp")

  [[ -n $lv ]] || continue

  case ",$layout," in
    *,raid0,*)  type=raid0 ;;
    *,raid1,*)  type=raid1 ;;
    *,raid4,*)  type=raid4 ;;
    *,raid5,*)  type=raid5 ;;
    *,raid6,*)  type=raid6 ;;
    *,raid10,*) type=raid10 ;;
    *,mirror,*) type=mirror ;;
    *,linear,*) type=linear ;;
    *,striped,*) type=striped ;;
    *)          type=${layout//,/+} ;;
  esac

  raid=-

  if [[ $layout == *raid* || $layout == *mirror* ]]; then
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

  pv_display=$(format_pvs "$pvs")

  printf '%-30.30s %7s %-9s %-8s %s\n' \
    "$vg/$lv" "$sz" "$type" "$raid" "$pv_display"

done < <(
  lvs --noheadings --separator '|' \
    -o vg_name,lv_name,lv_size,lv_layout,lv_health_status,copy_percent \
    2>/dev/null
)


# ---------------------------------------------------------------------------
# Btrfs
# ---------------------------------------------------------------------------

printf '\nBTRFS FILESYSTEMS\n'
printf '%-18s %7s %-19s %s\n' \
  FS SIZE PROFILE 'DEVICES(/dev/mapper/)'

declare -A seenfs

while read -r uuid mnt; do
  [[ -n $uuid ]] || continue
  [[ -z ${seenfs[$uuid]+x} ]] || continue

  seenfs[$uuid]=1

  label=$(findmnt -n -o LABEL "$mnt" 2>/dev/null | head -1)

  if [[ -z $label ]]; then
    label=${uuid:0:8}
  fi

  bytes=$(
    df -B1 --output=size "$mnt" 2>/dev/null |
      tail -1 |
      xargs
  )

  if [[ $bytes =~ ^[0-9]+$ ]]; then
    sz=$(numfmt --to=iec --suffix=B "$bytes")
  else
    sz='?'
  fi

  bdf=$(btrfs filesystem df "$mnt" 2>/dev/null || :)

  dp=$(
    sed -n 's/^Data, \([^:]*\):.*/\1/p' <<<"$bdf" |
      tr '[:upper:]' '[:lower:]' |
      paste -sd+ -
  )

  mp=$(
    sed -n 's/^Metadata, \([^:]*\):.*/\1/p' <<<"$bdf" |
      tr '[:upper:]' '[:lower:]' |
      paste -sd+ -
  )

  [[ -n $dp ]] || dp='?'
  [[ -n $mp ]] || mp='?'

  if [[ $dp == "$mp" ]]; then
    prof=$dp
  else
    prof="D:$dp/M:$mp"
  fi

  show=$(btrfs filesystem show "$mnt" 2>/dev/null || :)

  mapfile -t devs < <(
    sed -n 's/.* path \/dev\///p' <<<"$show" |
      sed 's#^mapper/##'
  )

  if ((${#devs[@]} == 0)); then
    devs=(-)
  fi

  printf '%-18.18s %7s %-19.19s %s\n' \
    "$label" "$sz" "$prof" "${devs[0]}"

  for ((i=1; i<${#devs[@]}; i++)); do
    printf '%47s%s\n' '' "${devs[i]}"
  done

done < <(
  findmnt -rn -t btrfs -o UUID,TARGET
)
