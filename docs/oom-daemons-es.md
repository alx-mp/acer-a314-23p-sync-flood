# 07 — Proyectos de GitHub / demonios de espacio de usuario contra el congelamiento por falta de memoria

**Equipo:** Acer Aspire A314-23P · Ryzen 5 7520U · 8 GB LPDDR5 (7,0 GiB visibles) · NVMe Micron 2450
**Sistema:** Fedora 44 Workstation · GNOME 50 Wayland · kernel **7.1.12-200.fc44** · systemd **259.8**
**Fecha del análisis:** 2026-09-03
**Alcance:** evaluar qué proyectos de terceros merece la pena **añadir** a las mitigaciones ya aplicadas (zram 7 GiB zstd + swapfile 4 GiB + sysctl + MGLRU `min_ttl_ms=1000` + drop-in de systemd-oomd + políticas de Chrome/Firefox + `check-alive-timeout`).

---

## 0. Estado real de la máquina en el momento del análisis (solo lectura)

Antes de recomendar nada, esto es lo que hay:

```
$ free -h
               total        used        free      shared  buff/cache   available
Mem:           7,0Gi       4,1Gi       414Mi        75Mi       3,0Gi       2,8Gi
Swap:           10Gi       339Mi        10Gi

$ cat /proc/swaps
/dev/zram0        partition  7326716  347964  100
/swap/swapfile    file       4194300       0   10

$ cat /sys/kernel/mm/lru_gen/enabled      -> 0x0007   (MGLRU completo activo)
$ cat /sys/kernel/mm/lru_gen/min_ttl_ms   -> 1000     (aplicado)
$ sysctl vm.swappiness vm.page-cluster vm.watermark_boost_factor vm.watermark_scale_factor
vm.swappiness = 133 / vm.page-cluster = 0 / vm.watermark_boost_factor = 0 / vm.watermark_scale_factor = 125
```

`oomctl` confirma que el drop-in **sí está aplicado** al gestor de usuario 1000:

```
Swap Used Limit: 90.00%
Default Memory Pressure Limit: 60.00%
Default Memory Pressure Duration: 20s
Swap Monitored CGroups:
    /user.slice/user-1000.slice/user@1000.service/app.slice      <- ManagedOOMSwap=kill OK
Memory Pressure Monitored CGroups:
    /user.slice/user-1000.slice/user@1000.service/app.slice
        Memory Pressure Limit: 50.00%                            <- el 50% OK (por defecto sería 80%)
```

*(Nota metodológica: `systemctl --user show app.slice` ejecutado como root muestra 80 % y `ManagedOOMSwap=auto` porque consulta el gestor de **root**, no el de UID 1000. La fuente de verdad es `oomctl`.)*

### 0.1. El OOM de hoy — la prueba de cargo

```
sep 03 10:26:07 HOSTNAME kernel: ThreadPoolForeg invoked oom-killer: gfp_mask=0x140cca(...), order=0, oom_score_adj=300
sep 03 10:26:07 HOSTNAME kernel: oom-kill:constraint=CONSTRAINT_NONE,nodemask=(null),cpuset=/,mems_allowed=0,
                                   global_oom,task_memcg=/user.slice/user-1000.slice/user@1000.service/app.slice/
                                   dbus-:1.2-org.gnome.Boxes@0.service,task=qemu-system-x86,pid=24322,uid=1000
sep 03 10:26:07 HOSTNAME kernel: Out of memory: Killed process 24322 (qemu-system-x86) total-vm:5082268kB,
                                   anon-rss:589108kB, ... oom_score_adj:200
```

Tres hechos que condicionan **todo** el resto del documento:

1. **`global_oom` / `CONSTRAINT_NONE`** → fue el OOM killer **global del kernel**, no un OOM de cgroup. Es decir, nadie en espacio de usuario llegó a tiempo.
2. **`journalctl -u systemd-oomd` no registra ni una sola acción** en los últimos 3 días — solo arranques y paradas del servicio. systemd-oomd **no intervino**.
3. **Quien disparó el OOM fue Chrome** (`ThreadPoolForeg`, `oom_score_adj=300` es el valor de un *renderer* de Chrome) **pero quien murió fue qemu** (la VM de Boxes). El kernel elige por `oom_score`, y no tiene ninguna noción de "prefiero perder una pestaña antes que una máquina virtual con estado".

Ese patrón exacto —systemd-oomd que no se dispara y deja pasar el OOM del kernel— está documentado en Red Hat Bugzilla #2248071, cerrado como EOL en diciembre de 2025 **sin solución**, con petición de reapertura en julio de 2026.

### 0.2. Lo que YA tienes instalado y no sabías que era la pieza clave: `uresourced` + `cgroupify`

```
$ rpm -q uresourced
uresourced-0.5.4-5.fc44.x86_64

$ cat /proc/16374/cgroup
0::/user.slice/.../app.slice/app-gnome-google\x2dchrome-16362.scope/16374
$ cat /proc/16371/cgroup
0::/user.slice/.../app.slice/app-cgroupify.slice/cgroupify@app-gnome-google\x2dchrome-16362.scope.service
```

Cada proceso hijo de Chrome está en **su propio sub-cgroup hoja**. Eso importa porque `man systemd-oomd`(8) dice literalmente:

> "systemd-oomd will select a cgroup to terminate, and send **SIGKILL** to all processes in it. Note that only descendant cgroups are eligible candidates... Also **only leaf cgroups** and cgroups with `memory.oom.group` set to **1** are eligible candidates."

Y el `NEWS.md` del propio paquete (`/usr/share/doc/uresourced/NEWS.md`, versión 0.4.0) lo explica:

> "Add new **cgroupify** component. This is a separte service that is intended to be used **together with systemd-oomd**. It is *not* recommended to install it unless systemd-oomd is used. The services moves every process in a unit into its own cgroup, **so that a systemd-oomd kill will only act on a single process**."

**Traducción:** cuando systemd-oomd *sí* actúa, mata **una pestaña**, no Chrome entero. Esta pieza —que es exactamente lo que Mozilla lleva pidiendo desde 2025 en el bug 1984223 y que aún no tiene— **ya la tienes activa y funcionando**. No hay que instalar nada aquí; sí hay que verificar que no se desactive.

---

## 1. Tabla comparativa

| Proyecto | Qué resuelve | Estado 2026 | ¿En Fedora 44? | ¿Aporta algo sobre lo ya aplicado? |
|---|---|---|---|---|
| **earlyoom** (`rfjakob/earlyoom`) | Mata el proceso más gordo cuando `MemAvailable` cae por debajo de un umbral **absoluto**, sondeando hasta 10 veces/s | **Vivo.** v1.9.0 publicada 2025-09-16 (añade `-P`, script pre-kill). C, MIT, sin dependencias | **Sí.** `earlyoom-1.9.0-2.fc44` (repo `fedora`, 40,8 KiB, mantenedor `vtrefny`) | **SÍ — la única adición con impacto real.** Cubre el hueco donde systemd-oomd no llega (ver §2). Requiere configuración específica (`-s 100`) para no quedar neutralizado por los 10,9 GiB de swap |
| **psi-notify** (`cdown/psi-notify`) | **Avisa** por notificación de escritorio cuando la presión PSI sube. **No mata nada** | **Vivo.** v1.3.1. MIT. Autor = Chris Down, mantenedor de systemd/PSI | **Sí.** `psi-notify-1.3.1-10.fc44` (repo `fedora`), trae `psi-notify.service` de usuario | **SÍ, pero como diagnóstico.** Riesgo cero. Da el "aviso antes de morir" que promete nohang, en un paquete oficial y mantenido |
| **uresourced / cgroupify** (freedesktop) | Protege `session.slice` con `MemoryMin`, y parte cada navegador en cgroups-hoja para que oomd mate **una pestaña** | **Vivo**, integrado en Fedora Workstation | **Sí — YA INSTALADO Y ACTIVO** (`0.5.4-5.fc44`) | **Nada que instalar.** Es la pieza más importante del conjunto y ya la tienes. Solo verificar |
| **nohang** (`hakavlad/nohang`) | earlyoom "con esteroides": avisos GUI antes de matar, acciones correctivas arbitrarias, consciente de zram, PSI | **Semi-abandonado.** Última *release* etiquetada: v0.3.0. Issues abiertas de 2023 y 2025 sin respuesta. Sin releases nuevas | **NO.** El paquete Fedora está **huérfano**; solo queda `nohang-0.2.0-5.el8` en EPEL 8. Únicas vías: COPR de terceros (`spaceguybob/nohang`, `atim/nohang`) | **NO.** Ver §3 |
| **prelockd** (`hakavlad/prelockd`) | `mlock()` sobre ejecutables y bibliotecas compartidas para que el kernel **nunca** pueda expulsar el código | Estancado (56 commits). Sin empaquetar en Fedora | **NO** | **Conceptualmente complementario a MGLRU, pero NO recomendable aquí.** Ver §4 — el análisis largo |
| **memavaild** (`hakavlad/memavaild`) | Ajusta `memory.high` en `user.slice`/`system.slice` para mantener `MemAvailable` ~3 % | Estancado (48 estrellas, 59 commits) | **NO** | **NO.** Duplica `MemoryHigh=` nativo de systemd, sin empaquetar |
| **le9 / le9ec** (`hakavlad/le9-patch`) | Parche de kernel: `vm.clean_low_kbytes`, `vm.clean_min_kbytes`, `vm.anon_min_kbytes` para reservar caché de código | **No fusionado upstream** (v1 a LKML en nov. 2021). Requiere recompilar kernel | **NO** | **NO, e imposible.** Su propio README: *"Multigenerational LRU disables le9 effects entirely"* — los sysctl **no tienen efecto con MGLRU activo**, y aquí `lru_gen/enabled = 0x0007` |
| **oomd** (`facebookincubator/oomd`) | El antepasado de systemd-oomd. PSI + cgroup v2 + sistema de plugins, orientado a flotas de servidores | Vivo pero de nicho (575 commits) | **NO** | **NO.** systemd-oomd es su derivado y ya está corriendo. Redundante |
| **bustd** (`pop-os/bustd`) | OOM killer en Rust basado en PSI, se auto-`mlockall()` para seguir respondiendo bajo thrashing | Nicho, específico de Pop!_OS, sin releases recientes visibles | **NO** | **NO.** Mismo papel que earlyoom pero sin paquete ni mantenimiento comparable |
| **ananicy-cpp** | Prioridades de CPU/IO por perfil de aplicación | Vivo | **NO** (`dnf info ananicy-cpp` → sin coincidencias) | **NO.** Es un problema de **memoria**, no de CPU. Fuera de alcance |
| **zram-generator** | Genera el dispositivo zram como swap | Vivo | **Sí — YA INSTALADO** (`1.2.1-5.fc44`) | Nada nuevo. Ya configurado a `min(ram,8192)` + zstd + prio 100 |
| **OOMAnalyser** (buscar `OOMAnalyser` en GitHub) | Analiza y visualiza un volcado de OOM del kernel. **Forense, no preventivo** | Vivo (actualizado ago. 2026) | No (es una web/Python) | **Marginal pero útil:** puedes pegar tu `oom-kernel-2026-09-03T1026.log` para leerlo cómodamente |
| **BPF OOM** (Roman Gushchin, Google) | Programar la política del OOM killer **en el kernel** vía BPF; explícitamente aspira a hacer innecesarios los demonios de espacio de usuario | Serie de parches v1 (2025-08-18), aún **no fusionada** | No | **Nada hoy.** Es el futuro a vigilar, no una opción |

Otros proyectos que aparecen en `github.com/topics/oom-killer` con actividad 2025-2026 y que revisé y descarté por no ser demonios de prevención: `oom-tui` (forense en Rust, ago. 2026), `zram-tuning` (scripts de benchmark de zram, ene. 2026), `mknight` (vigila bucles de `malloc` en sandbox, jun. 2026), `memlimit` (limitador sin root, abr. 2026), `kube-resource-suggest` (Kubernetes). Ninguno es relevante para un escritorio Fedora.

---

## 2. earlyoom: cómo funciona, cómo convive con systemd-oomd, y por qué **sí** en este equipo

### 2.1. Mecánica

`earlyoom` es un binario de C de 40 KiB sin dependencias más allá de glibc y systemd. Lee `/proc/meminfo` **hasta 10 veces por segundo** (menos si sobra memoria) y compara:

- **`-m PERCENT[,KILL_PERCENT]`** — porcentaje mínimo de memoria *disponible* (`MemAvailable`). Por defecto **10 %** para SIGTERM y **5 %** para SIGKILL.
- **`-s PERCENT[,KILL_PERCENT]`** — porcentaje mínimo de swap *libre*. Por defecto 10 % / 5 %.
- **`-M` / `-S`** — lo mismo pero en KiB absolutos.

**El detalle crítico**, en palabras del propio MANPAGE:

> "earlyoom sends SIGTERM once **both** available memory **and** free swap are below their respective PERCENT settings."

Es decir: **hacen falta las dos condiciones a la vez**. Y a continuación:

> "You can use **`-s 100`** to have earlyoom effectively ignore swap usage: Processes are killed once available memory drops below the configured minimum, **no matter how much swap is free**."

Otras opciones relevantes:

| Opción | Efecto |
|---|---|
| `--prefer REGEX` | Multiplica la "maldad" de los procesos que casan → se matan antes |
| `--avoid REGEX` | Divide la maldad → se matan los últimos |
| `--ignore REGEX` | Nunca se consideran candidatos |
| `-r SEGUNDOS` | Intervalo del informe de memoria en el journal (por defecto 1 s; `0` lo desactiva) |
| `-p` | Se auto-prioriza: `nice -20` y `oom_score_adj -100`, para seguir respondiendo bajo thrashing |
| `-n` | Notificaciones D-Bus **vía `systembus-notify`** |
| `-N` / `-P` | Script a ejecutar después / antes de matar (`-P` es nuevo en 1.9.0) |
| `--sort-by-rss` | Ordena por RSS en lugar de por `oom_score` |
| `--dryrun` | Simula sin matar |

Configuración en Fedora: fichero `/etc/default/earlyoom`, variable `EARLYOOM_ARGS`. **Las expresiones regulares no se entrecomillan y no pueden contener espacios** (hay que usar `[[:space:]]`).

**Aviso concreto para Fedora 44:** la opción `-n` es **inútil aquí**, porque `systembus-notify` **no está empaquetado** (`dnf info systembus-notify` → "No hay paquetes que se correspondan"). No la pongas.

### 2.2. ¿Choca con systemd-oomd? La posición oficial y por qué la matizo

**La posición oficial de Fedora es que NO se usen los dos.** La `Changes/EnableSystemdOomd` (Fedora 34) describe la migración como:

```
sudo systemctl disable --now earlyoom
sudo systemctl enable --now systemd-oomd
```

y en la lista `fedora-devel`, cuando un usuario reportó que tras actualizar a F34 corrían ambos, **Neal Gompa** respondió:

> "**No.** The earlyoom service is supposed to get disabled on upgrade to Fedora Linux 34. **This is a bug and needs to be fixed.**"

El argumento técnico habitual (hilo de Hacker News, comentario de *TheDong*) es que systemd-oomd es arquitectónicamente superior:

> "systemd-oomd / oomd ... use **PSI**, which the kernel itself is updating over time, and they just poll that, while earlyoom is also internally making its own estimates at a **lower granularity** than the kernel does." · "earlyoom keeps getting suggested ... just because people are used to using it ... from back before the kernel had cgroups v2."

**Eso es correcto en general. Pero en ESTA máquina hay tres agujeros medibles:**

**Agujero 1 — la vía "swap" de systemd-oomd está matemáticamente muerta.** `man oomd.conf`(5) sobre `SwapUsedLimit=`:

> "Sets the limit for memory and swap usage on the system before systemd-oomd will take action. **If the fraction of memory used AND the fraction of swap used on the system are BOTH more than what is defined here**, systemd-oomd will act on eligible descendant control groups with swap usage greater than 5 % of total swap... **Defaults to 90 %.**"

Con **10,9 GiB de swap total** (7 GiB zram + 4 GiB swapfile), esa condición exige **~9,8 GiB de swap ocupada** *además de* >90 % de RAM usada. Para llegar ahí el equipo lleva ya varios minutos inservible. Es decir: el swapfile de 4 GiB, que es correcto por otras razones (evita el `Free swap = 0kB` del kernel), tiene el **efecto colateral** de alejar todavía más el disparo por swap de oomd. No es motivo para quitarlo, pero sí para no contar con esa vía.

**Agujero 2 — la vía "presión PSI" necesita 20 s sostenidos.** `ManagedOOMMemoryPressureLimit=50 %` durante `DefaultMemoryPressureDurationSec=20s`. Veinte segundos de presión de memoria al 50 % en un portátil de 7 GiB **son exactamente el congelamiento del que se queja el usuario**: es en esa ventana cuando mutter deja de recibir respuesta del cliente Wayland y GNOME saca el diálogo de "forzar cierre o esperar".

**Agujero 3 — evidencia empírica en este equipo.** El OOM de las 10:26 fue `global_oom` del kernel con **cero entradas de systemd-oomd** en el journal. Y ese fallo está documentado y **sin resolver**: RHBZ #2248071, donde Anita Zhang (autora de systemd-oomd) dice *"I suspect the pressure is not meeting the thresholds we have set by default for Fedora"*, Adam Williamson confirma que el kernel dispara su propio killer antes, y el comité de bloqueadores de Fedora lo rechaza como blocker con el razonamiento de que *"we have no release criteria covering what should happen if you run your system out of memory, and it will always be something bad"*. Cerrado como EOL en dic. 2025, reapertura pedida en jul. 2026.

En el foro de Fedora hay usuarios describiendo lo mismo: `tail /dev/zero` congela el equipo con systemd-oomd activo, y **earlyoom sí mata el proceso**.

**Conclusión matizada:** no se trata de "dos OOM killers compitiendo". Se trata de **dos sensores distintos**: systemd-oomd mira **presión PSI y % de swap**; earlyoom mira **`MemAvailable` absoluta**. Configurando earlyoom con umbrales que solo se alcanzan cuando oomd **ya ha fallado**, earlyoom actúa como **red de seguridad de último recurso**, no como competidor. El precio de equivocarse es bajo (un proceso muerto de más, casi siempre una pestaña); el precio de no tenerlo es el congelamiento que motiva todo este caso.

### 2.3. Configuración concreta recomendada para este equipo

```ini
# /etc/default/earlyoom
#
# -m 10,5  SIGTERM cuando MemAvailable < 10 % de 7,0 GiB (~717 MiB);
#          SIGKILL por debajo del 5 % (~358 MiB). Son los valores por defecto de upstream.
# -s 100   IMPRESCINDIBLE AQUI. Sin esto, earlyoom exigiria ADEMAS que quedara <10 % de swap
#          libre; con 10,9 GiB de swap eso no pasa nunca y earlyoom no dispararia jamas.
#          MANPAGE: "You can use -s 100 to have earlyoom effectively ignore swap usage".
# -r 3600  Un informe de memoria por hora en el journal (por defecto es 1/segundo = ruido).
# -p       earlyoom se pone nice -20 y oom_score_adj -100 para seguir vivo bajo thrashing.
# --avoid  Nucleo de la sesion grafica: si earlyoom mata gnome-shell pierdes el escritorio
#          entero. session.slice ya esta protegido por uresourced (MemoryMin=250M) pero
#          earlyoom no entiende de cgroups, hay que decirselo por nombre.
# --prefer Renderers de Chrome y procesos de contenido de Firefox: son recargables.
#          (Los renderers de Chrome ya llevan oom_score_adj=300, asi que earlyoom los
#           elegiria igualmente; --prefer solo lo hace determinista.)
# NO usar -n: requiere systembus-notify, que NO esta empaquetado en Fedora 44.
# Las regex NO se entrecomillan y NO pueden llevar espacios literales (usar [[:space:]]).

EARLYOOM_ARGS=-m 10,5 -s 100 -r 3600 -p --avoid (^|/)(systemd|systemd-oomd|systemd-journal|systemd-logind|dbus-broker|gnome-shell|gnome-session-b|gnome-keyring-d|Xwayland|pipewire|wireplumber|gdm|gdm-session-wor|sshd)$ --prefer (^|/)(chrome|chromium|Web[[:space:]]Content|Isolated[[:space:]]Web[[:space:]]Co|Privileged[[:space:]]Cont)$
```

**Sobre `qemu-system-x86`:** deliberadamente **no** lo pongo en `--avoid`. Si la VM de Boxes es realmente el proceso más grande, debe seguir siendo candidata; pero al estar Chrome en `--prefer`, earlyoom irá primero a por una pestaña, que es lo que quieres. Si prefieres blindar la VM a toda costa, añade `qemu-system-x86` al `--avoid` — con la contrapartida de que entonces morirán varias pestañas seguidas antes de tocarla.

**Si resulta demasiado agresivo** (mata pestañas cuando el equipo aún iba bien), baja a `-m 6,3`. **Si sigue llegando el OOM del kernel antes que earlyoom**, sube a `-m 15,8`.

---

## 3. nohang: por qué NO

`nohang` es técnicamente el más completo de todos: avisos GUI **antes** de matar (`low memory warnings`), acciones correctivas arbitrarias en lugar de matar (`systemctl restart foo`), selección de víctima por nombre / cgroup / ruta del ejecutable / variables de entorno / UID, consciente de zram, soporte PSI, dos perfiles (`nohang.conf` y `nohang-desktop.conf`), y utilidades de diagnóstico (`oom-sort`, `psi-top`, `psi2log`).

**Tres razones para descartarlo, en orden de peso:**

1. **No está empaquetado para Fedora.** El paquete Fedora está **huérfano**: solo sobrevive `nohang-0.2.0-5.el8` en **EPEL 8**, que ni siquiera es aplicable a Fedora 44. Las únicas vías son COPRs de terceros (`copr.fedorainfracloud.org/coprs/spaceguybob/nohang`, `atim/nohang`). Meter un COPR sin mantenedor conocido para un demonio que corre como root y decide qué procesos matar es un riesgo desproporcionado.

2. **Mantenimiento tibio.** La última *release* etiquetada es v0.3.0; hay commits en `master` pero issues abiertas de 2023 y 2025 sin respuesta. Comparado con earlyoom (v1.9.0 en septiembre de 2025, en el repo oficial de Fedora con mantenedor Fedora asignado), la diferencia es grande.

3. **Está escrito en Python.** Un demonio de prevención de OOM escrito en un intérprete que necesita **asignar memoria** para ejecutar su bucle de decisión es exactamente el tipo de cosa que falla cuando más lo necesitas. earlyoom es C estático de 40 KiB con `-p`; `bustd` llega al extremo de hacerse `mlockall()` a sí mismo por este motivo.

**Lo único que perderías de nohang —el aviso GUI antes de matar— lo cubre `psi-notify`, que sí está en los repos de Fedora 44.**

---

## 4. prelockd / memavaild / le9 y la pregunta clave: ¿MGLRU `min_ttl_ms` los hace innecesarios?

Esta es la sección que más importa, porque es donde la respuesta intuitiva es **incorrecta**.

### 4.1. El problema clásico

Cuando la RAM se agota, el kernel recupera memoria expulsando páginas. Entre esas páginas está el **código ejecutable mapeado**: los `.so` de GTK, de Chrome, las fuentes, el propio binario de `gnome-shell`. Como son páginas *limpias* respaldadas por fichero, expulsarlas es "gratis" (no hay que escribirlas). Pero la siguiente vez que el proceso ejecuta esa función, hay que releerla del NVMe. Como describe el README de prelockd, puedes acabar **golpeando el disco en cada llamada a función**. El escritorio se congela mucho **antes** de que el OOM killer entre en acción, porque técnicamente no falta memoria: el kernel está "resolviendo" el problema, muy despacio. ValdikSS lo llamó "efecto avalancha": el sistema transfiere *"program executables, libraries and swap back and forth"*.

### 4.2. Qué hace realmente `min_ttl_ms` (lo que ya tienes aplicado)

`docs.kernel.org/admin-guide/mm/multigen_lru.html`, literalmente:

> "Users can write `N` to `min_ttl_ms` to prevent the working set of `N` milliseconds from getting evicted. **The OOM killer is triggered if this working set cannot be kept in memory.**"
> "Based on the average human detectable lag (~100 ms), `N=1000` usually eliminates intolerable janks due to thrashing."

La documentación lo describe como *"an adjustable pressure relief valve"* — **una válvula de alivio de presión**.

Dos cosas que la documentación **no** dice y conviene tener claras:

- **No distingue tipos de página.** Protege "el conjunto de trabajo de los últimos N ms" — código, datos, caché de fichero, todo junto, por edad de generación. No es una protección específica del código ejecutable.
- **Su mecanismo de "protección" es disparar el OOM killer.** No evita la expulsión: **cambia el fallo**. En lugar de thrashear indefinidamente, mata algo. Y **el que mata es el OOM killer del KERNEL**, que no sabe nada de cgroupify, ni de `--prefer`, ni de systemd-oomd. Elige por `oom_score`.

### 4.3. Qué hace prelockd

`mlock()` sobre los mapeos de ejecutables y bibliotecas compartidas. Esas páginas pasan a ser **`Unevictable`**: ningún algoritmo de reclamación —LRU clásico, MGLRU, el que venga— puede tocarlas. Es una garantía **absoluta y por tipo de página**, no estadística ni temporal.

### 4.4. Respuesta: **son complementarios, y MGLRU NO cubre este problema — de hecho hoy lo empeora**

Esto no es opinión. Hay tres fuentes de 2026:

**(a) Phoronix, 27 de agosto de 2026 — "Linux 7.3 MGLRU Change Helps Executable Code Stays In Memory".** Baolin Wang (Alibaba) envía parches porque:

> MGLRU ha sido **"less reliable"** protegiendo los *mapped executable file folios*, que **se reclaman más fácilmente que con el comportamiento del LRU clásico**, mientras que *"classical LRU protects mapped executable file folios for better chances of staying in system memory to avoid I/O thrashing"*.

Su banco de pruebas —un servidor ARM de 32 núcleos con **2 GB de RAM** compilando el kernel con 32 trabajos— pasó de **9248 s a 7861 s de tiempo de sistema** con los parches.

**(b) LWN, 20 de mayo de 2026 — "What is to be done about MGLRU?".** Shakeel Butt: *"Memory reclaim in the kernel is a mess. We ship two completely separate eviction algorithms — traditional LRU and MGLRU — in the same file."* Entre los defectos concretos que se listan: **"MGLRU does not adequately protect the page cache"** y, explícitamente, **páginas ejecutables** con esquemas de prioridad distintos entre ambas implementaciones.

**(c) LWN, 6 de marzo de 2026.** Bajo MGLRU, *"file and anon pages [are placed] on an equal footing in terms of age-based eviction"* — es decir, MGLRU **renuncia** deliberadamente al trato de favor que el LRU clásico daba a las páginas ejecutables.

**Y el corolario práctico: este equipo corre el kernel 7.1.12. El arreglo llega en 7.3.**

Así que la respuesta honesta a la pregunta es:

> **NO. `min_ttl_ms=1000` no cubre el problema de prelockd.** Son mecanismos ortogonales: `min_ttl_ms` es un temporizador global que **convierte el thrashing en un OOM kill**; prelockd es un candado permanente **sobre un tipo concreto de página**. Además, en kernels 6.1–7.2 MGLRU es *peor* que el LRU clásico protegiendo código ejecutable, según los propios desarrolladores del kernel, y el arreglo está en camino para 7.3.

### 4.5. Y aun así: **NO instales prelockd en este equipo**

Cuatro razones, en orden:

1. **Aritmética de RAM.** prelockd hace **unevictable** todo el código de Chrome + Firefox + la pila de GNOME. En un equipo de 7,0 GiB eso son varios cientos de MiB **permanentemente secuestrados**, que dejan de estar disponibles para todo lo demás. En un equipo de 32 GiB es un intercambio excelente; en uno de 7 GiB con una VM de 3 GiB puedes estar **agravando** el mismo problema que quieres resolver. La cuenta no sale.
2. **Cero empaquetado.** No hay RPM ni COPR. Habría que compilar e instalar a mano un demonio que corre como root un servicio permanente, y mantenerlo tú a cada actualización.
3. **El efecto principal que buscas ya lo da `min_ttl_ms`.** Aunque el mecanismo sea distinto, el resultado observable —"deja de congelarse durante minutos y mata algo rápido"— es el mismo que el propio README de prelockd usa como demo (*"With prelockd enabled... no freezes, the OOM killer comes quickly with fast system recovery"*).
4. **El arreglo correcto llega solo.** Los parches de Baolin Wang para 7.3 llegarán a Fedora 44 por actualización normal del kernel. Instalar un demonio no empaquetado para tapar un hueco que el kernel va a cerrar en dos versiones es mal negocio.

### 4.6. memavaild y le9: descartados sin matices

- **`le9` es literalmente imposible aquí.** Su propio README: **"Multigenerational LRU disables le9 effects entirely"** — los sysctl `vm.clean_low_kbytes` / `vm.clean_min_kbytes` / `vm.anon_min_kbytes` **no tienen efecto** cuando MGLRU está activo, y aquí `lru_gen/enabled` vale `0x0007`. Además nunca se fusionó upstream (v1 a LKML en noviembre de 2021) y exige recompilar el kernel. Descartado por partida triple.
- **`memavaild`** ajusta `memory.high` sobre `user.slice`/`system.slice` para mantener `MemAvailable` en torno al 3 %. Eso es exactamente lo que systemd sabe hacer de forma nativa con `MemoryHigh=` en un drop-in, sin demonio externo, sin Python y sin código sin empaquetar. Si algún día quieres esa palanca, se hace con systemd, no con memavaild.

---

## 5. ⚠️ Interacción a vigilar: `min_ttl_ms` puentea a TODOS los demonios de espacio de usuario

Esto no estaba en el encargo pero sale directamente de las fuentes y afecta a lo ya aplicado, así que lo dejo por escrito.

`min_ttl_ms=1000` hace que, cuando el conjunto de trabajo de 1 s no cabe, **el kernel dispare su propio OOM killer**. Ese killer:

- **no** consulta a systemd-oomd,
- **no** sabe que cgroupify ha partido Chrome en cgroups-hoja para poder matar una sola pestaña,
- **no** conoce `--prefer` ni `--avoid`,
- elige por `oom_score` — y así es **exactamente** como murió `qemu-system-x86` (la VM con estado) a las 10:26 en lugar de una pestaña de Chrome recargable.

*(Precisión: el `min_ttl_ms` se aplicó a las ~12:07 de hoy, después de ese OOM de las 10:26. No causó aquel evento. Pero el mecanismo es el que es, y describe lo que puede volver a pasar.)*

**No propongo revertirlo** — `N=1000` es el valor que recomienda la documentación del kernel y el compromiso "morir rápido antes que congelarse" es el correcto para el síntoma que se está atacando. Pero si con el tiempo observas que **la VM de Boxes muere una y otra vez mientras Chrome sobrevive**, la causa es esta, y la palanca es:

```bash
# Probar 500 ms (más tolerante: thrashea un poco más, dispara el OOM del kernel menos)
sudo sed -i 's|min_ttl_ms - - - - 1000|min_ttl_ms - - - - 500|' /etc/tmpfiles.d/99-lru_gen.conf
sudo systemd-tmpfiles --create /etc/tmpfiles.d/99-lru_gen.conf

# O desactivarlo del todo y dejar que actúen oomd + earlyoom (que sí saben a quién matar)
echo 0 | sudo tee /sys/kernel/mm/lru_gen/min_ttl_ms
```

Nótese la simetría con la recomendación de earlyoom: **cuanto más eficaces sean oomd y earlyoom, menos falta hace que el kernel tome la decisión por su cuenta.**

---

## 6. Veredicto

### 6.1. ✅ INSTALAR

**(1) `psi-notify` — riesgo cero, alto valor diagnóstico**

Avisa por notificación de escritorio cuando la presión PSI sube, **antes** de que nada muera. No mata nunca nada. Está en el repo oficial de Fedora 44 y lo mantiene Chris Down, que es a la vez el autor del artículo de referencia sobre zram/zswap y contribuidor de systemd/PSI. Su README lo dice: *"psi-notify sidesteps this problem by simply notifying, rather than taking action."*

```bash
sudo dnf install -y psi-notify

mkdir -p ~/.config
cat > ~/.config/psi-notify <<'EOF'
# Comprobar cada 5 s
update 5

# Umbral de memoria: si los procesos han estado bloqueados esperando memoria
# mas del 10 % del tiempo en los ultimos 10 s, avisar. Con systemd-oomd fijado
# al 50 % durante 20 s, esto te avisa MUCHO antes de que oomd mate nada.
threshold memory some avg10 10.00

# Umbral de E/S: el thrashing de swap se ve aqui antes que en ningun otro sitio.
threshold io some avg10 25.00

# CPU alto para que no sea ruidoso (compilar o un build de podman lo dispararia)
threshold cpu some avg10 80.00
EOF

systemctl --user enable --now psi-notify.service
systemctl --user status psi-notify.service --no-pager
```

**(2) `earlyoom` — la red de seguridad de último recurso**

```bash
sudo dnf install -y earlyoom

sudo tee /etc/default/earlyoom > /dev/null <<'EOF'
# Ver 07-proyectos-github-oom.md, seccion 2.3, para la justificacion de cada flag.
# -s 100 es IMPRESCINDIBLE: con 10,9 GiB de swap, sin el earlyoom no disparara nunca.
EARLYOOM_ARGS=-m 10,5 -s 100 -r 3600 -p --avoid (^|/)(systemd|systemd-oomd|systemd-journal|systemd-logind|dbus-broker|gnome-shell|gnome-session-b|gnome-keyring-d|Xwayland|pipewire|wireplumber|gdm|gdm-session-wor|sshd)$ --prefer (^|/)(chrome|chromium|Web[[:space:]]Content|Isolated[[:space:]]Web[[:space:]]Co|Privileged[[:space:]]Cont)$
EOF

# Prueba en seco ANTES de activarlo de forma permanente (Ctrl-C para salir):
sudo /usr/bin/earlyoom --dryrun -m 10,5 -s 100 -r 5

sudo systemctl enable --now earlyoom.service
systemctl status earlyoom.service --no-pager
```

**(3) Verificar `uresourced`/`cgroupify` — ya instalado, solo comprobar**

```bash
rpm -q uresourced
systemctl --user status uresourced.service --no-pager
# La comprobacion que de verdad importa: cada proceso hijo de Chrome en su propio cgroup hoja
for p in $(pgrep -f 'type=renderer' | head -3); do cat /proc/$p/cgroup; done
```

Debe verse la ruta terminando en `.../app-gnome-google\x2dchrome-NNNN.scope/NNNNN`. **Si algún día dejara de verse, has perdido la capacidad de matar una sola pestaña** y systemd-oomd volvería a matar Chrome entero.

### 6.2. ❌ NO INSTALAR

| Proyecto | Motivo principal |
|---|---|
| **nohang** | Huérfano en Fedora (solo EPEL 8), sin releases nuevas, demonio Python en el camino crítico de OOM. Su única ventaja real (avisos GUI) la da `psi-notify`, empaquetado y mantenido |
| **prelockd** | Aritmética: haría *unevictable* código por valor de cientos de MiB en un equipo de 7,0 GiB con una VM de 3 GiB. Sin empaquetar. Y el arreglo correcto (parches de Baolin Wang para MGLRU) llega en Linux 7.3 |
| **le9 / le9ec** | **Sin efecto con MGLRU activo**, según su propio README. Nunca fusionado upstream. Exige recompilar el kernel |
| **memavaild** | Duplica `MemoryHigh=` nativo de systemd. Sin empaquetar, estancado |
| **oomd (Facebook)** | systemd-oomd es su derivado y ya está corriendo. Orientado a flotas de servidores |
| **bustd** | Mismo papel que earlyoom, sin paquete Fedora ni mantenimiento equiparable |
| **ananicy-cpp** | Prioridades de CPU/IO, no memoria. Fuera de alcance. Ni siquiera está en Fedora 44 |
| **Cambiar zram por zswap** | Chris Down lo defiende en abstracto (*"If in doubt, prefer to use zswap"*) por la **inversión de LRU** que provoca zram+disco. Es un argumento serio y aplica a tu configuración zram(prio 100)+swapfile(prio 10). **Pero es una reforma del §01, no un "proyecto de GitHub", y contradice lo ya aplicado.** Lo dejo señalado como línea de investigación separada, no como recomendación de este documento |

### 6.3. Cómo comprobar que earlyoom y systemd-oomd no se pisan

```bash
# Los dos vivos, y quien actua en cada evento:
journalctl -f -u earlyoom -u systemd-oomd

# Estado de oomd (umbrales y presion en vivo):
oomctl

# Historial de acciones de earlyoom (deberia estar casi siempre vacio:
# si earlyoom actua a menudo, es que oomd no esta llegando, y hay que
# bajar ManagedOOMMemoryPressureDurationSec o revisar la carga real):
journalctl -u earlyoom --since today | grep -i 'sending SIG'

# OOM del kernel (esto SIEMPRE deberia estar vacio; si no, ni oomd ni earlyoom llegaron):
journalctl -k --since today | grep -i 'Out of memory'
```

**Regla de lectura de resultados:**
- Solo actúa **oomd** → configuración ideal, earlyoom nunca hace falta pero está de red.
- Actúa **earlyoom** → oomd no llegó; earlyoom hizo su trabajo. Considera bajar `ManagedOOMMemoryPressureDurationSec` a 10 s.
- Actúa el **kernel** (`global_oom`) → ninguno de los dos llegó. Sube `-m` en earlyoom (p. ej. `-m 15,8`) y/o baja `min_ttl_ms`.

### 6.4. Revertir

```bash
sudo systemctl disable --now earlyoom.service
sudo dnf remove -y earlyoom
systemctl --user disable --now psi-notify.service
sudo dnf remove -y psi-notify
rm -f ~/.config/psi-notify
```

---

## 7. ¿Existe una solución definitiva tipo "librería que lo arregla"?

**No. Y conviene decirlo sin rodeos, porque la pregunta lleva implícita una expectativa que ninguna de estas herramientas puede cumplir.**

**Primero: no es un bug, es una escasez.** Chrome con muchas pestañas + Firefox + una VM de 3 GiB + podman + Claude Code sobre **7,0 GiB visibles** es una sobresuscripción de memoria. Ningún demonio crea RAM. Todo lo que hay en este documento —earlyoom, nohang, oomd, prelockd, le9, systemd-oomd— hace exactamente **una** cosa: decidir **quién muere y cuándo**, para que no muera el escritorio entero. Convierten un congelamiento en una muerte selectiva. Eso es valioso, pero es una gestión de daños, no una cura.

**Segundo: el propio kernel no tiene todavía una respuesta consensuada.** Es lo más revelador de esta investigación. En mayo de 2026, LWN titula literalmente *"What is to be done about MGLRU?"* y recoge a Shakeel Butt diciendo que *"memory reclaim in the kernel is a mess. We ship two completely separate eviction algorithms in the same file"*, con el resultado de que *"every bug fix, every optimization, every feature has to be done twice or it only works for half the users"*. En agosto de 2026 todavía se están enviando parches para que MGLRU proteja el código ejecutable tan bien como lo hacía el LRU clásico de hace veinte años. Y la propuesta de Roman Gushchin (Google, agosto de 2025) para programar el OOM killer con **BPF** justifica su existencia diciendo que hay *"multiple opinions on what the best policy is"* y que aspira a eliminar la necesidad de demonios de espacio de usuario como systemd-oomd. Si el mecanismo estándar fuera suficiente, esa propuesta no existiría.

**Tercero: la comparación con Windows 11 es real, pero no es "Windows lo tiene arreglado".** Windows aplica una política **distinta**, no una tecnología mágica: compresión de memoria (equivalente a tu zram), un *pagefile* que **crece dinámicamente** en el NVMe en lugar de tener un tamaño fijo, y una suspensión agresiva de procesos y pestañas en segundo plano. Es un compromiso diferente —Windows prefiere ir muy despacio antes que matar algo—, y sobre las mismas piezas de silicio produce una sensación distinta. La pieza de esa política que **sí** puedes copiar ya la has copiado: Memory Saver de Chrome y `browser.tabs.unloadOnLowMemory` de Firefox son, literalmente, la suspensión de pestañas de Windows.

**Cuarto: lo más parecido a una solución definitiva que sí existe.** En orden de eficacia real:

1. **Más RAM.** Es la única solución de verdad. En el A314-23P la LPDDR5 del 7520U suele ir **soldada**, así que conviene verificarlo antes de contar con ello — pero si hubiera un zócalo libre, 8 GiB más resuelven el caso entero y hacen irrelevante todo este documento.
2. **Bajar la demanda.** La VM de Boxes a **2 GiB** en lugar de 3 recupera 1 GiB, que sobre 7,0 GiB es el **14 % de la máquina**. No ejecutar Boxes y una sesión pesada de Chrome a la vez vale más que cualquier demonio.
3. **Que muera lo correcto.** Aquí es donde **ya estás muy bien situado**, mejor de lo que la mayoría cree: `cgroupify` + `systemd-oomd` matan **una pestaña** en lugar de Chrome entero, y esa combinación —que Mozilla lleva pidiendo desde 2025 en el bug 1984223 y aún no tiene— la tienes activa por defecto en Fedora Workstation.
4. **Que muera pronto en vez de congelarse.** `min_ttl_ms=1000` + earlyoom.

**El resumen honesto:** de los diez y pico proyectos evaluados, **dos merecen instalarse** (earlyoom como red de último recurso, psi-notify como aviso previo), **uno ya lo tenías sin saberlo y es el más importante** (cgroupify), y **el resto son irrelevantes, imposibles o contraproducentes en un equipo de 7 GiB con MGLRU**. La ganancia neta de este documento no es "instala esto y se arregla": es **saber por qué systemd-oomd no se disparó el 3 de septiembre a las 10:26**, y añadir el único componente que sí habría llegado a tiempo.

---

## 8. Fuentes

**earlyoom**
- README y MANPAGE: https://github.com/rfjakob/earlyoom · https://raw.githubusercontent.com/rfjakob/earlyoom/master/MANPAGE.md
- Paquete Fedora (1.9.0-2.fc44, mantenedor `vtrefny`): https://packages.fedoraproject.org/pkgs/earlyoom/earlyoom/
- `systembus-notify` (dependencia de `-n`, no empaquetada en Fedora): https://github.com/rfjakob/systembus-notify
- Configuración de escritorio con `-s` consciente de swap: https://gist.github.com/davidar/243ca325716c4cca0baf14a7b3069857

**systemd-oomd y la posición de Fedora**
- Fedora Change (F34), incluye la migración explícita desde earlyoom: https://fedoraproject.org/wiki/Changes/EnableSystemdOomd
- Neal Gompa, *"The earlyoom service is supposed to get disabled on upgrade... This is a bug"*: https://www.spinics.net/lists/fedora-devel/msg288061.html
- `man oomd.conf`(5), semántica exacta de `SwapUsedLimit=` ("**both** more than"): https://www.freedesktop.org/software/systemd/man/latest/oomd.conf.html (verificado localmente con `man -P cat oomd.conf`, systemd 259.8)
- `man systemd-oomd`(8), *"only leaf cgroups... are eligible candidates"* y *"user@$UID.service may prefer a much lower value like 40%"*: https://man.archlinux.org/man/systemd-oomd.8.en
- RHBZ #2248071 — *systemd-oomd doesn't kick in on high memory pressure, leading to system lockup* (cerrado EOL dic. 2025, sin resolver, reapertura pedida jul. 2026): https://bugzilla.redhat.com/show_bug.cgi?id=2248071
- Fedora Discussion — systemd-oomd no funciona, earlyoom sí mata el proceso: https://discussion.fedoraproject.org/t/systemd-oomd-not-working-on-my-desktop/128243
- Fedora Discussion — congelamientos por OOM: https://discussion.fedoraproject.org/t/out-of-memory-and-the-system-freezes-systemd-oomd-working-correctly-or-not/100771
- systemd #23095 — systemd-oomd y la detección de swap zram: https://github.com/systemd/systemd/issues/23095
- systemd #35270 — *systemd-oomd keeps bringing down my whole DE*: https://github.com/systemd/systemd/issues/35270

**uresourced / cgroupify**
- Upstream: https://gitlab.freedesktop.org/benzea/uresourced
- Paquete Fedora: https://packages.fedoraproject.org/pkgs/uresourced/uresourced/index.html
- `NEWS.md` v0.4.0, *"so that a systemd-oomd kill will only act on a single process"*: fichero local `/usr/share/doc/uresourced/NEWS.md`
- Fedora Change — reserva de recursos para el usuario activo: https://fedoraproject.org/wiki/Changes/Reserve_resources_for_active_user_WS
- Mozilla bug 1984223 — Firefox necesita ser consciente de cgroups/systemd-oomd (sin confirmar desde 2025): https://bugzilla.mozilla.org/show_bug.cgi?id=1984223

**MGLRU, `min_ttl_ms` y la protección del código ejecutable**
- Documentación del kernel (`min_ttl_ms`, *"The OOM killer is triggered if this working set cannot be kept in memory"*): https://docs.kernel.org/admin-guide/mm/multigen_lru.html
- Fuente `.rst` upstream (bitmask `enabled` 0x0001/0x0002/0x0004): https://raw.githubusercontent.com/torvalds/linux/master/Documentation/admin-guide/mm/multigen_lru.rst
- **Phoronix, 2026-08-27** — *Linux 7.3 MGLRU Change Helps Executable Code Stays In Memory* (Baolin Wang; MGLRU "less reliable" con folios ejecutables mapeados): https://www.phoronix.com/news/Linux-7.3-MGLRU-Executable-Mem
- **LWN, 2026-05-20** — *What is to be done about MGLRU?* (Shakeel Butt; MGLRU no protege bien la page cache ni las páginas ejecutables): https://lwn.net/Articles/1072866/
- **LWN, 2026-03-06** — MGLRU pone *"file and anon pages on an equal footing in terms of age-based eviction"*: https://lwn.net/Articles/1061800/
- `mg-lru-helper` (scripts para fijar `min_ttl_ms` a 1000 en el arranque): https://github.com/hakavlad/mg-lru-helper/blob/main/README.md

**Proyectos de hakavlad**
- prelockd: https://github.com/hakavlad/prelockd
- memavaild: https://github.com/hakavlad/memavaild
- le9-patch (*"Multigenerational LRU disables le9 effects entirely"*): https://github.com/hakavlad/le9-patch
- nohang: https://github.com/hakavlad/nohang · releases: https://github.com/hakavlad/nohang/releases
- Paquete Fedora de nohang (**huérfano**, solo EPEL 8): https://packages.fedoraproject.org/pkgs/nohang/nohang/
- COPR no oficial: https://copr.fedorainfracloud.org/coprs/spaceguybob/nohang
- ValdikSS, *Linux for old PC from 2007* (el "efecto avalancha" y le9): https://notes.valdikss.org.ru/linux-for-old-pc-from-2007/en/

**Otros**
- psi-notify: https://github.com/cdown/psi-notify
- oomd (Facebook): https://github.com/facebookincubator/oomd · https://facebookmicrosites.github.io/oomd/
- bustd (Pop!_OS, Rust + PSI + `mlockall`): https://github.com/pop-os/bustd
- Chris Down, *Debunking zswap and zram myths* (2026-03-24): https://chrisdown.name/2026/03/24/zswap-vs-zram-when-to-use-what.html
- Phoronix, 2025-08-18 — *New Linux Patches Allow Manipulating Out-Of-Memory Behavior Using BPF* (Roman Gushchin, Google): https://www.phoronix.com/news/Linux-OOM-BPF-Proposal
- Fedora Discussion — problemas de OOM con zram en Fedora 44: https://discussion.fedoraproject.org/t/serious-oom-problems-with-zram-installing-fedora-44-with-zswap/189385
- `github.com/topics/oom-killer` (barrido de proyectos 2024-2026): https://github.com/topics/oom-killer
- OOMAnalyser (forense de volcados OOM, útil para `oom-kernel-2026-09-03T1026.log`) — localizado vía el topic `oom-killer`, propietario del repo no verificado: https://github.com/topics/oom-killer
