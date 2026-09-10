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
# Genau EIN LVM-Scan.
#
# Enthält:
#   - sichtbare LVs
#   - interne RAID-LVs
#   - alle Segmente
#   - deren Backing Devices
#
lvm_report=$(
  lvs -a --segments --noheadings --separator '|' \
    -o vg_name,lv_name,lv_size,lv_layout,lv_health_status,copy_percent,devices \
    2>/dev/null || :
)


# ---------------------------------------------------------------------------
# PV-Spalten bestimmen
# ---------------------------------------------------------------------------

mapfile -t pv_columns < <(
  awk -F'|' '
  function clean(x) {
    gsub(/^[ \t]+|[ \t]+$/, "", x)
    return x
  }

  {
    n=split($7,a,",")

    for (i=1; i<=n; i++) {
      x=clean(a[i])

      sub(/\([0-9]+\)$/, "", x)
      gsub(/^\[/, "", x)
      gsub(/\]$/, "", x)

      if (x ~ /^\/dev\//) {
        sub(/^\/dev\//, "", x)
        print x
      }
    }
  }
  ' <<<"$lvm_report" |
    sort -Vu
)

#
# Normalerweise 4 Zeichen:
#
# sda,
# sdb,
#
# Bei längeren PV-Namen automatisch breiter.
#
pv_width=4

for p in "${pv_columns[@]}"; do
  if ((${#p} + 1 > pv_width)); then
    pv_width=$((${#p} + 1))
  fi
done


# ---------------------------------------------------------------------------
# PV-Matrix formatieren
# ---------------------------------------------------------------------------

format_pvs() {
  local csv=$1
  local p col out="" i j last=-1 comma cell

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

  ((last >= 0)) || {
    printf '-'
    return
  }

  for ((i=0; i<=last; i++)); do
    col=${pv_columns[i]}
    cell=""

    if [[ ${member[$col]+x} ]]; then
      comma=""

      for ((j=i+1; j<=last; j++)); do
        if [[ ${member[${pv_columns[j]}]+x} ]]; then
          comma=","
          break
        fi
      done

      cell="${col}${comma}"
    fi

    printf -v cell "%-${pv_width}s" "$cell"
    out+=$cell
  done

  printf '%s' "$out"
}


# ---------------------------------------------------------------------------
# LVM-Graph EINMAL auswerten
# ---------------------------------------------------------------------------

while IFS='|' read -r vg lv sz layout health cp pvs; do
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

  pv_display=$(format_pvs "${pvs:--}")

  printf '%-30.30s %7s %-9s %-8s %s\n' \
    "$vg/$lv" "$sz" "$type" "$raid" "$pv_display"

done < <(
  awk -F'|' '

  function clean(x) {
    gsub(/^[ \t]+|[ \t]+$/, "", x)
    return x
  }

  function depclean(x) {
    x=clean(x)

    sub(/\([0-9]+\)$/, "", x)
    gsub(/^\[/, "", x)
    gsub(/\]$/, "", x)

    return x
  }

  function addpv(x) {
    sub(/^\/dev\//, "", x)

    if (pvseen[x] != generation) {
      pvseen[x]=generation
      pv[++npv]=x
    }
  }

  function walk(vg,lv, k,n,a,i,x) {
    k=vg SUBSEP lv

    if (seen[k] == generation || !(k in deps))
      return

    seen[k]=generation

    n=split(deps[k],a,",")

    for (i=1; i<=n; i++) {
      x=depclean(a[i])

      if (x ~ /^\/dev\//) {
        addpv(x)
      } else if ((vg SUBSEP x) in deps) {
        walk(vg,x)
      }
    }
  }

  {
    vg=clean($1)

    raw=clean($2)
    lv=raw

    gsub(/^\[/, "", lv)
    gsub(/\]$/, "", lv)

    k=vg SUBSEP lv

    #
    # Alle Segmente desselben LV zusammenführen.
    #
    d=$7

    if (deps[k] != "")
      deps[k]=deps[k] "," d
    else
      deps[k]=d

    #
    # Interne LVM-LVs stehen bei "lvs -a" in [].
    # Nur öffentliche LVs später ausgeben.
    #
    if (raw !~ /^\[/) {
      if (!(k in public)) {
        public[k]=1
        order[++count]=k

        vgs[k]=vg
        lvs[k]=lv
        sizes[k]=clean($3)
        layouts[k]=clean($4)
        healths[k]=clean($5)
        copies[k]=clean($6)
      }
    }
  }

  END {
    for (z=1; z<=count; z++) {
      k=order[z]

      generation++
      npv=0

      #
      # Sichtbares LV rekursiv bis zu den echten PVs verfolgen.
      #
      walk(vgs[k],lvs[k])

      list=""

      for (i=1; i<=npv; i++)
        list=list (i==1 ? "" : ",") pv[i]

      print \
        vgs[k] "|" \
        lvs[k] "|" \
        sizes[k] "|" \
        layouts[k] "|" \
        healths[k] "|" \
        copies[k] "|" \
        list
    }
  }
  ' <<<"$lvm_report"
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
  [[ -n $label ]] || label=${uuid:0:8}

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
