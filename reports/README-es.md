# Paquete de reporte: reinicios espontáneos Acer Aspire A314-23P / Fedora 44

Todo el contenido de los cinco documentos está **en inglés** y listo para copiar y pegar.
Los adjuntos están en `attachments/`.

## Antes de enviar nada, lee esto

Los cinco parámetros de kernel que arreglaron tu equipo son un **rodeo específico de esta
máquina**. Fedora no los va a activar para todos los usuarios en una actualización, porque
apagan funciones de ahorro de energía que en la mayoría de los portátiles funcionan bien.

Lo que sí puede acabar en una actualización futura es:

1. **El backport de amdgpu** (documento 02). Es una corrección que ya existe hecha por AMD y
   solo hay que traerla a la versión de kernel de Fedora. Es la petición con más
   probabilidades de prosperar.
2. **Un "quirk" para este modelo**, es decir, que el kernel detecte este Acer concreto y
   desactive por sí solo lo que haga falta. Para eso hace falta que los desarrolladores de
   AMD o del kernel confirmen la causa, y para eso sirve el documento 03.
3. **Una corrección de BIOS de Acer** (documento 04). Según AMD, los sync floods debe
   depurarlos el fabricante del equipo.

## Orden recomendado de envío

| # | Archivo | Dónde | Necesitas |
| --- | --- | --- | --- |
| 1 | `02-fedora-bugzilla-compbuf-backport.md` | https://bugzilla.redhat.com — Product Fedora, Component kernel, Version 44 | cuenta de Red Hat Bugzilla (gratis) |
| 2 | `01-fedora-bugzilla-sync-flood.md` | igual que el anterior | la misma cuenta |
| 3 | `03-gitlab-drm-amd-issue.md` | https://gitlab.freedesktop.org/drm/amd/-/issues/new | cuenta de freedesktop GitLab |
| 4 | `04-acer-support-warranty.md` | https://www.acer.com/us-en/support o el servicio técnico de tu país | número de serie (ya está en el texto) |
| 5 | `05-linux-pm-amd-gfx-mailing-list.md` | correo a linux-pm@vger.kernel.org, con copia a amd-gfx@lists.freedesktop.org | correo en **texto plano**, sin HTML |

Empieza por el 02 porque es el más sencillo y concreto. El 01 y el 03 se refuerzan
mutuamente: pon en cada uno el enlace del otro una vez creados.

## Adjuntos

En `attachments/` tienes los archivos que se citan al final de cada documento. En Bugzilla
se suben con "Add an attachment" después de crear el reporte. En GitLab se arrastran al
cuadro de texto. A Acer se envían por correo.

## Consejo

Espera a tener 24-48 horas de funcionamiento estable antes de enviarlos, y añade ese dato
("no resets in N hours with these parameters"), porque es la prueba más fuerte que puedes
aportar. Si en cambio vuelve a reiniciarse, dilo también: cambia el diagnóstico y hace más
probable que sea la memoria soldada, es decir, garantía.
