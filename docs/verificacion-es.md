# Verificación de todo lo aplicado — 2026-09-03

Comprobado en el sistema en funcionamiento después de aplicar los cambios.

| # | Qué se comprobó | Resultado | Veredicto |
| --- | --- | --- | --- |
| 1 | Los 5 parámetros están en los 3 kernels (7.1.12, 6.19.10, rescate) | 1 aparición de cada uno en cada entrada, sin duplicados | CORRECTO |
| 2 | La entrada de rescate sigue siendo válida | intacta y con los parámetros | CORRECTO |
| 3 | `$tuned_params` no se perdió al editar | presente en las dos entradas de kernel | CORRECTO |
| 4 | GRUB lee las entradas nuevas sin regenerar `grub.cfg` | `grub.cfg` usa `blscfg` (3 referencias) | CORRECTO |
| 5 | Los 5 parámetros están activos en el kernel en marcha | los 5 en `/proc/cmdline` | CORRECTO |
| 6 | El estado de sueño profundo desapareció | solo quedan POLL, C1 y C2 (antes había C3 de 350 µs) | CORRECTO |
| 7 | El SSD ya no se duerme solo | `default_ps_max_latency_us` = 0, APST deshabilitado | CORRECTO |
| 8 | El ahorro del bus PCIe está apagado de verdad | `ASPM Disabled` en SSD y WiFi, subestados L1.1/L1.2 apagados | CORRECTO |
| 9 | El apagado automático de la gráfica está desactivado | `ppfeaturemask` = 0xfff73fff (bit 0x8000 quitado) | CORRECTO |
| 10 | El kernel ya ve los errores del bus PCIe | `AER: enabled` en los 3 puertos raíz | CORRECTO |
| 11 | Los tres servicios arrancan solos y funcionan | los 3 `enabled` y `active`, sin errores en su registro | CORRECTO |
| 12 | Etiquetas de SELinux de los scripts propios | `bin_t`, correcto para `/usr/local/sbin` | CORRECTO |
| 13 | El registro de motivos de reinicio funciona | ya tiene 4 entradas, la última correcta | CORRECTO |
| 14 | Memoria de intercambio total | zram 7 GiB (prioridad 100) + archivo 4 GiB (prioridad 10) | CORRECTO |
| 15 | Compresión de zram | pasó a `zstd` | CORRECTO |
| 16 | Ajustes del kernel de memoria | swappiness 133, page-cluster 0, watermark_scale 125 | CORRECTO |
| 17 | Protección del conjunto de trabajo (MGLRU) | `min_ttl_ms` = 1000 | CORRECTO |
| 18 | Etiqueta SELinux del archivo de intercambio | `swapfile_t`, correcta | CORRECTO |
| 19 | `/etc/fstab` es válido y el intercambio montará al arrancar | verificado, unidad de systemd generada | CORRECTO |
| 20 | Reloj en hora universal | `/etc/adjtime` dice UTC | CORRECTO |
| 21 | No hay Windows que se vea afectado por el cambio de reloj | 0 entradas de arranque de Windows | CORRECTO |
| 22 | Política de Chrome y de Firefox instaladas | JSON válido en ambas rutas | CORRECTO |
| 23 | Tiempo antes del diálogo "no responde" | 20000 ms | CORRECTO |
| 24 | systemd-oomd vigila el intercambio de las aplicaciones | app.slice del usuario al 50 % y con vigilancia de intercambio | CORRECTO |
| 25 | Prueba de esfuerzo de 15 minutos | 11 pruebas, 0 fallos, sin reinicio ni errores de hardware | CORRECTO |

## Riesgos aceptados conscientemente

* **Más consumo en reposo.** Al desactivar cuatro funciones de ahorro de energía, la batería
  durará menos y el equipo estará algo más caliente en reposo. Es el precio de la estabilidad
  mientras no se sepa cuál de las cuatro es la culpable. `REVERTIR.md` explica cómo ir quitándolas
  de una en una para recuperar autonomía.
* **`pcie_ports=native`** hace que el kernel tome el control de servicios del bus PCIe que el
  firmware quería para sí. Es lo que permite ver los errores, pero es un cambio de reparto de
  responsabilidades. No ha dado ningún problema en las pruebas.
* **`min_ttl_ms=1000`** protege lo que estás usando a costa de que, en un apuro extremo de
  memoria, el kernel mate un programa antes en lugar de congelarse. Es el comportamiento deseado
  aquí, pero es un cambio de criterio.
* **La política de Chrome bloquea el ajuste en su interfaz.** Si quieres volver a controlarlo tú,
  borra `/etc/opt/chrome/policies/managed/10-memory-saver.json`.

## Lo que no se puede verificar desde el software

Que la memoria RAM esté sana. Va soldada, no tiene ECC y la BIOS de Acer no expone tablas de
errores de hardware. Solo un memtest largo lo descarta.

## Único indicador que importa a partir de ahora

```bash
cat /var/log/motivo-reset.log
```

Que no vuelva a aparecer `0x08000800`.
