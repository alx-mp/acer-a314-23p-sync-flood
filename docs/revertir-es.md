# Cómo deshacer todo lo aplicado el 2026-09-03

Cada bloque es independiente. Todo se ejecuta como root salvo donde se indique.

## 1. Parámetros de kernel (los que frenan los reinicios)

Quitar todos de una vez:

```bash
grubby --update-kernel=ALL --remove-args="processor.max_cstate=2 nvme_core.default_ps_max_latency_us=0 pcie_ports=native amdgpu.ppfeaturemask=0xfff73fff pcie_aspm.policy=performance"
sed -i 's/ processor.max_cstate=2 nvme_core.default_ps_max_latency_us=0 pcie_ports=native amdgpu.ppfeaturemask=0xfff73fff pcie_aspm.policy=performance//' /etc/default/grub
```

**Para aislar cuál es el que hace falta** (lo interesante si quieres recuperar autonomía),
quítalos de uno en uno en este orden y espera 24-48 horas entre cada paso vigilando
`/var/log/motivo-reset.log`:

1. `amdgpu.ppfeaturemask=0xfff73fff`
2. `pcie_ports=native`
3. `pcie_aspm.policy=performance`
4. `nvme_core.default_ps_max_latency_us=0`
5. `processor.max_cstate=2` (este el último: es el principal sospechoso)

Ejemplo para quitar uno solo: `grubby --update-kernel=ALL --remove-args="pcie_ports=native"`

Copias de seguridad originales: `/root/diagnostico-reinicios/bls-backup/` y
`/root/diagnostico-reinicios/grub.default.bak-*`.

## 2. Servicios propios

```bash
systemctl disable --now registrar-motivo-reset.service mitigacion-syncflood.service
rm -f /etc/systemd/system/registrar-motivo-reset.service /etc/systemd/system/mitigacion-syncflood.service
rm -f /usr/local/sbin/registrar-motivo-reset /usr/local/sbin/mitigacion-syncflood
systemctl daemon-reload
```

## 3. rasdaemon y stress-ng

```bash
systemctl disable --now rasdaemon
dnf remove -y rasdaemon stress-ng
```

## 4. Reloj del hardware a hora local (no recomendado)

```bash
timedatectl set-local-rtc 1
```

## 5. Ajustes de memoria (kernel, zram, oomd)

```bash
bash /home/USER/diagnostico-reinicios/ram/revertir.sh
```

## 6. Archivo de intercambio en disco

```bash
swapoff /swap/swapfile
sed -i '\#^/swap/swapfile#d' /etc/fstab
btrfs subvolume delete /swap
```

## 7. Chrome, Firefox y GNOME

```bash
bash /home/USER/diagnostico-reinicios/ram/revertir-apps.sh
```

O suelto:

```bash
rm -f /etc/opt/chrome/policies/managed/10-memory-saver.json
rm -f /etc/firefox/policies/policies.json
# como USER, dentro de la sesión gráfica:
gsettings reset org.gnome.mutter check-alive-timeout
```

## Si quieres volver al kernel anterior para comparar

```bash
grubby --set-default /boot/vmlinuz-6.19.10-300.fc44.x86_64   # usar el viejo
grubby --set-default /boot/vmlinuz-7.1.12-200.fc44.x86_64    # volver al actual
grubby --default-kernel                                       # ver cuál está puesto
```

## Códigos que verás en /var/log/motivo-reset.log

| Código | Significado |
| --- | --- |
| `0x08000800` | **Sync flood**: reset de hardware por error no corregible. Es el fallo que perseguimos. |
| `0x00080800` | Reinicio normal pedido por el sistema operativo. Esto es lo bueno. |
| Otros con "thermal" | Apagado por temperatura. |
| Otros con "power button" | Botón de encendido mantenido pulsado. |
| Otros con "watchdog" | Perro guardián del hardware. |

## 8. Demonios de memoria añadidos el 2026-09-03 (segunda tanda)

```bash
systemctl disable --now earlyoom.service
rm -f /etc/default/earlyoom
sudo -u USER XDG_RUNTIME_DIR=/run/user/1000 systemctl --user disable --now psi-notify.service
rm -f /home/USER/.config/psi-notify
dnf remove -y earlyoom psi-notify
```

Si algún día ves que **la máquina virtual muere una y otra vez mientras Chrome sobrevive**,
la causa es `min_ttl_ms`, que hace decidir al kernel en lugar de a los demonios. Palanca:

```bash
sed -i 's|min_ttl_ms - - - - 1000|min_ttl_ms - - - - 500|' /etc/tmpfiles.d/99-lru_gen.conf
systemd-tmpfiles --create /etc/tmpfiles.d/99-lru_gen.conf
```
