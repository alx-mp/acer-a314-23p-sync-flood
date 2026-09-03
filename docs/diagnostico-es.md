# Informe: por qué se reiniciaba el equipo y qué se hizo

**Equipo:** Acer Aspire A314-23P · Ryzen 5 7520U · 8 GB LPDDR5 · Fedora 44 · kernel 7.1.12
**Fecha:** 3 de septiembre de 2026

---

## 1. Qué pasaba

El procesador AMD se reiniciaba a sí mismo por un error irrecuperable en su bus interno. No era
un fallo de Fedora, ni un programa que se colgara, ni tú apagando el equipo a la fuerza.

## 2. Cómo se supo

Los procesadores AMD modernos guardan en un registro interno el motivo del último reinicio, y el
kernel lo lee y lo escribe en el log al arrancar. En los ocho arranques que siguieron a un corte
apareció siempre lo mismo:

```
x86/amd: Previous system reset reason [0x08000800]:
         an uncorrected error caused a data fabric sync flood event
```

Mientras que tras los reinicios normales aparece otra cosa distinta:

```
x86/amd: Previous system reset reason [0x00080800]:
         software wrote 0x6 to reset control register 0xCF9
```

La correspondencia fue exacta: cada corte brusco del log iba seguido de un aviso de "sync flood",
y cada reinicio voluntario iba seguido del aviso de "reinicio por software".

Un *sync flood* es una protección del propio chip: cuando detecta un error que no puede corregir
en el bus que une procesador, memoria, PCIe y gráficos, se resetea de inmediato. Por eso no había
ningún registro de fallo: el sistema operativo no llega ni a enterarse.

### Los ocho cortes

| Arranque | Empezó | Último registro | Duró | Motivo del corte |
| --- | --- | --- | --- | --- |
| -8 | 00:16 | 00:18:49 | 2 min 56 s | sync flood |
| -6 | 05:40 | 06:11:16 | 31 min | sync flood |
| -5 | 06:11 | 07:22:55 | 1 h 11 min | sync flood |
| -4 | 07:29 | 10:34:18 | 2 h 57 min | sync flood |
| -3 | 10:39 | 10:40:16 | 1 min 16 s | sync flood |
| -2 | 10:42 | 11:19:55 | 38 min | sync flood |
| -1 | 11:22 | 11:28:49 | 6 min | sync flood |

### El dato que descarta el botón de encendido

Los discos SSD llevan dos contadores internos: cuántas veces han recibido corriente y cuántas
veces se les ha cortado de golpe. Comparé esos contadores antes y después de uno de los
reinicios y **no cambiaron**. Es decir, el disco nunca se quedó sin corriente. Fue un reinicio
en caliente ordenado por el chip, no un apagón ni el botón mantenido pulsado.

## 3. Qué NO era

Durante el diagnóstico aparecieron varios mensajes de error llamativos. Ninguno era la causa:

* **El aviso largo de la tarjeta gráfica** (`dcn31_program_compbuf_size`): es un fallo conocido
  introducido en el kernel 7.0, ya corregido por AMD en una versión que Fedora todavía no tiene.
  Aparece también en los arranques que no se reiniciaron, incluido el actual.
* **El error del monitor HDMI** (`vendor infoframe -22`): el monitor externo HDMI no anuncia una función
  opcional del estándar HDMI. Cosmético.
* **Los errores de ACPI y de Bluetooth**: defectos del firmware de Acer, idénticos en todos los
  arranques.
* **La falta de memoria que mató la máquina virtual**: ocurrió una vez, ocho minutos antes de un
  corte, pero otros cortes pasaron sin ninguna presión de memoria, uno de ellos a los 76 segundos
  de arrancar.

## 4. Qué se cambió

### Arranque del sistema

Se añadieron cinco opciones al arranque, en los tres kernels instalados:

| Opción | Qué hace, en palabras simples |
| --- | --- |
| `processor.max_cstate=2` | Impide que el procesador entre en su modo de sueño más profundo. Es el principal sospechoso del fallo. |
| `nvme_core.default_ps_max_latency_us=0` | Impide que el disco SSD se duerma solo. |
| `pcie_aspm.policy=performance` | Impide que el bus PCIe apague partes de sí mismo para ahorrar. |
| `pcie_ports=native` | Hace que el kernel vea los errores del bus PCIe, que la BIOS de Acer le ocultaba. |
| `amdgpu.ppfeaturemask=0xfff73fff` | Impide que la tarjeta gráfica se apague sola cuando no dibuja. |

**Un detalle importante que costó descubrir:** al principio se usó `pcie_aspm=off`, que es lo que
recomienda casi todo el mundo en internet, y **no funcionó**. Esa opción significa literalmente
"no toques nada y deja lo que puso la BIOS", y la BIOS de este Acer lo deja activado. Hubo que
cambiarla por `pcie_aspm.policy=performance`, y con esa sí se desactivó de verdad.

**Coste:** el equipo consume algo más en reposo y la batería dura un poco menos. Sin riesgo para
tus datos y todo reversible.

### Vigilancia

* Un servicio propio anota en `/var/log/motivo-reset.log` el motivo de cada reinicio. Es tu
  termómetro para saber si esto quedó resuelto.
* Otro servicio vuelve a aplicar las protecciones en caliente por si acaso.
* Se instaló `rasdaemon`, que archiva cualquier error de hardware que sí llegue a registrarse.
* El reloj del hardware pasó a hora universal (antes estaba en hora local, lo cual solo tiene
  sentido si compartes el equipo con Windows, y aquí no hay Windows).

### Memoria

Fedora venía configurado solo con memoria comprimida (zram) y **sin ningún archivo de intercambio
en disco**. Ese es el motivo de que Windows nunca se te congelara y Fedora sí: Windows siempre
tiene su archivo de paginación como red de seguridad. Cuando aquí se llenaban los 7 GiB, no había
a dónde ir.

* Se añadió un **archivo de intercambio de 4 GiB en disco**, con prioridad baja para que solo se
  use cuando la memoria comprimida se agote. Ahora tienes 11 GiB de respaldo en vez de 7.
* La memoria comprimida pasó de `lzo-rle` a **zstd**, que comprime bastante más.
* Se activó **MGLRU con un mínimo de 1000 ms**, que impide al kernel expulsar de la memoria lo que
  estás usando ahora mismo. Esto ataca directamente el congelamiento.
* Se ajustaron cuatro parámetros del kernel para que reaccione antes y no lea de más al usar zram.
* **systemd-oomd** ahora vigila también el consumo de intercambio de tus aplicaciones y cierra una
  sola pestaña o la máquina virtual antes de que el sistema entero se atasque.
* **Chrome** tiene activado el ahorro de memoria en nivel máximo, que suspende las pestañas que no
  usas. **Firefox** descarga pestañas cuando queda poca memoria, algo que en Linux venía apagado.
* El diálogo de **"la aplicación no responde: forzar cierre o esperar"** aparecía a los 5 segundos.
  Ahora espera 20 segundos, que es lo razonable en un equipo que usa intercambio.

## 5. Prueba de esfuerzo y ventilador

Quince minutos de carga máxima simultánea de procesador, memoria y disco: **11 pruebas, 0 fallos,
ningún reinicio, ningún error de hardware.**

| Medida | Reposo | Carga máxima | 30 s después |
| --- | --- | --- | --- |
| Procesador (interior del chip) | 40 °C | 92 °C | 46 °C |
| Gráficos | 38 °C | 71 °C | 43 °C |
| Carcasa | 40 °C | 63 °C | 55 °C |
| Disco SSD | 35 °C | 51 °C | – |

**El ventilador funciona.** Que el chip baje de 92 °C a 46 °C en treinta segundos solo es posible
con refrigeración activa; sin ventilador tardaría varios minutos. Y **el sensor mide bien**: marca
la temperatura del silicio, no la de la carcasa, por eso no notas el equipo hirviendo. Los 92 °C
son el tope que el propio firmware le pone al chip, y es normal en un portátil delgado a tope.

## 6. Cómo comprobar en los próximos días

El único indicador que importa:

```bash
cat /var/log/motivo-reset.log
```

Si tras cada arranque pone `0x00080800 software wrote 0x6` significa que fue un reinicio normal:
bien. Si vuelve a aparecer `0x08000800 sync flood`, la mitigación no bastó.

Comprobar que las protecciones siguen puestas:

```bash
cat /proc/cmdline
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name    # debe faltar C3
swapon --show                                            # zram + swapfile
```

## 7. Si vuelve a reiniciarse

1. **Prueba la memoria.** Es lo único que no se puede descartar por software, y la RAM va soldada.
   Instala `memtest86+`, desactiva temporalmente el Arranque Seguro en la BIOS (tecla F2 al
   encender), arranca la entrada de memtest desde el menú y déjalo dar al menos 4 pasadas. Vuelve
   a activar el Arranque Seguro después. Alternativa sin tocar la BIOS: MemTest86 de PassMark
   desde un USB.
2. **Prueba el kernel anterior** un día entero: elígelo en el menú de arranque, o fíjalo con
   `grubby --set-default /boot/vmlinuz-6.19.10-300.fc44.x86_64`.
3. **Garantía.** Tienes la carta lista en `fedora-package/04-acer-support-warranty.md` con todos
   los adjuntos preparados. Como la memoria va soldada, un fallo de memoria implica cambiar la
   placa.

## 8. Cómo revertir

Todo está detallado en `REVERTIR.md`, cambio por cambio, con el orden recomendado para ir
quitando opciones de una en una si quieres recuperar autonomía de batería.

## 9. Lo que queda pendiente

* **Bajar la máquina virtual de 3 GiB a 2 GiB.** No lo hice porque cambia cómo funciona *tu*
  máquina virtual y esa decisión es tuya. Si quieres, con la caja apagada:
  `virsh -c qemu:///session setmaxmem my-vm 2G --config && virsh -c qemu:///session setmem my-vm 2G --config`
* **BIOS y firmware del SSD:** no hay versiones más nuevas disponibles hoy.
* **Enviar los reportes:** ver `fedora-package/README.md`.

## Fuentes

* https://docs.kernel.org/arch/x86/amd-debugging.html
* https://raw.githubusercontent.com/torvalds/linux/master/arch/x86/kernel/cpu/amd.c
* https://gitlab.freedesktop.org/drm/amd/-/work_items/3556
* https://gitlab.freedesktop.org/drm/amd/-/issues/4841
* https://community.frame.work/t/fw13-amd-ai-300-hx-370-48-data-fabric-sync-flood-crashes-in-2-months-comprehensive-data/80338
* https://lore.kernel.org/all/20260604145428.809959-24-aurabindo.pillai@amd.com/
* https://docs.kernel.org/admin-guide/mm/multigen_lru.html
* https://btrfs.readthedocs.io/en/latest/Swapfile.html
