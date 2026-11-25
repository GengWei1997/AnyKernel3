### AnyKernel custom methods
## Helium_Studio @ CoolApk

# Locate the dtb appended to Image.gz-dtb and print its byte offset.
#
# A raw FDT header starts with magic d0 0d fe ed followed by a big-endian
# totalsize. Requiring totalsize == bytes remaining rules out the (rare)
# chance of the magic appearing inside the gzip stream.
#
# The scan walks backwards from the end of the file instead of using
# "grep -abo", because the busybox shipped with AnyKernel3 has no -b option
# (it fails with "grep: invalid option -- b"), which silently disabled the
# dtb patch and produced an unbootable image.
find_dtb_offset() {
  local f="$1"
  local total chunk start abs tsize

  total=$(wc -c < "$f") || return 1;

  for chunk in 1048576 4194304 16777216 67108864 268435456; do
    [ "$chunk" -gt "$total" ] && chunk=$total;
    start=$((total - chunk));
    [ "$start" -lt 0 ] && start=0;

    abs=$(tail -c +$((start + 1)) "$f" 2>/dev/null | head -c "$chunk" 2>/dev/null | \
      od -An -v -tx1 2>/dev/null | \
      awk -v base="$start" '
        {
          for (i = 1; i <= NF; i++) {
            if ($i == "d0" && $(i+1) == "0d" && $(i+2) == "fe" && $(i+3) == "ed") {
              print base + (NR - 1) * 16 + (i - 1);
              exit;
            }
          }
        }');

    if [ "$abs" ]; then
      tsize=$(od -An -v -tu1 -j $((abs + 4)) -N 4 "$f" 2>/dev/null | \
        awk '{ printf "%d", $1 * 16777216 + $2 * 65536 + $3 * 256 + $4 }');
      if [ "$tsize" = "$((total - abs))" ]; then
        echo "$abs";
        return 0;
      fi;
    fi;

    [ "$chunk" -ge "$total" ] && break;
  done;

  return 1;
}

patch_dtb() {
  local work="$AKHOME/.dtbwork"
  local src

  rm -rf "$work";
  mkdir -p "$work";

  if [ -f "$AKHOME/dtb" ] && [ -f "$AKHOME/Image.gz" ]; then
    # Separate payloads: dtb is already standalone.
    src="$AKHOME/dtb";

  elif [ -f "$AKHOME/Image.gz-dtb" ]; then
    # Kernel and dtb are concatenated. Split them in-place on device so the
    # dtb can be patched, then rejoin.
    local offset;
    offset=$(find_dtb_offset "$AKHOME/Image.gz-dtb");

    if [ -z "$offset" ]; then
      ui_print " " "Warning: could not locate appended dtb, using image as-is...";
      rm -rf "$work";
      return 0;
    fi;

    ui_print " " "Found appended dtb at offset $offset";
    tail -c +$((offset + 1)) "$AKHOME/Image.gz-dtb" > "$work/dtb";
    head -c "$offset" "$AKHOME/Image.gz-dtb" > "$work/kernel.gz";
    src="$work/dtb";

  else
    ui_print " " "Warning: no dtb found, skipping dtb patch...";
    rm -rf "$work";
    return 0;
  fi;

  grep -q "logical" /vendor/etc/fstab.qcom;
  if [ $? -eq 0 ]; then
    fdtput "$src" /firmware/android boot_devices soc/1d84000.ufshc -ts;
    fdtput "$src" /firmware/android/vbmeta compatible -d;
    fdtput "$src" /firmware/android/vbmeta parts -d;
    fdtput "$src" -r /firmware/android/fstab;
    ui_print " " "Retrofit dynamic partitions detected. Using patched dtb...";
  else
    local fs_type;
    fs_type=$(mount | grep ' /vendor ' | awk '{print $5}');
    if [ "$fs_type" = "erofs" ]; then
      fdtput "$src" /firmware/android/fstab/vendor type erofs -ts;
      fdtput "$src" /firmware/android/fstab/vendor mnt_flags ro -ts;
      ui_print " " "Vendor EROFS detected. Using patched dtb...";
    else
      ui_print " " "No special cases detected. Using default dtb...";
    fi;
  fi;

  if [ -f "$work/kernel.gz" ]; then
    # Rebuild the appended-dtb image with the patched dtb.
    cat "$work/kernel.gz" "$work/dtb" > "$AKHOME/Image.gz-dtb.new";
    mv -f "$AKHOME/Image.gz-dtb.new" "$AKHOME/Image.gz-dtb";
    ui_print " " "Rebuilt Image.gz-dtb with patched dtb.";
  fi;

  rm -rf "$work";
}

clean_cache() {
  ui_print " " "Installation done. Cleaning cache...";
  rm -rf /cache/*;
  rm -rf /data/dalvik-cache;
  rm -rf /data/resource-cache;
  rm -rf /data/system/package_cache;
}
