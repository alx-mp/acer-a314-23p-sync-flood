#!/bin/bash
# OPCIONAL (prioridad baja). Red de seguridad en disco detrás de zram. Leer antes de ejecutar; como root.
# Fuente: https://btrfs.readthedocs.io/en/latest/Swapfile.html y btrfs-filesystem(8) "mkswapfile"
#  - el fichero debe ser NOCOW y preasignado (mkswapfile lo hace: sin compresión ni checksums)
#  - el subvolumen que lo contiene NO se puede instantanear (snapshot) mientras esté activo
#  - balance/scrub saltan los block groups del swapfile
#  - prioridad: zram queda en 100 (zram-generator), el fichero en 10 -> se usa sólo cuando zram está lleno
set -euo pipefail
btrfs subvolume create /swap
chmod 700 /swap
btrfs filesystem mkswapfile --size 4g /swap/swapfile
swapon --priority 10 /swap/swapfile
grep -q '^/swap/swapfile' /etc/fstab || echo '/swap/swapfile none swap defaults,pri=10,nofail 0 0' >> /etc/fstab
swapon --show
# Si SELinux deniega swapon: ausearch -m avc -ts recent ; semanage fcontext -a -t swapfile_t '/swap/swapfile' ; restorecon -v /swap/swapfile
# Revertir: swapoff /swap/swapfile ; sed -i '\#^/swap/swapfile#d' /etc/fstab ; btrfs subvolume delete /swap
# Si se activa, bajar vm.swappiness a 100-133 en 02-99-ram.conf (el disco es mucho más lento que zram).
