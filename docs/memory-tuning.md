# Memory tuning on 8 GB with zram

A second problem showed up while diagnosing the resets. With many browser tabs open the desktop
would lock up and GNOME would offer to force-quit the application. On the same machine under
Windows 11 that never happened.

## Why it happens

Fedora configures zram and no disk swap at all. zram is compressed memory, so it lives inside
the same 7 GiB of RAM it is meant to relieve. Once it fills, there is nowhere left to put
anything, and the kernel either thrashes or starts killing processes. Windows always keeps a
pagefile on disk as a second tier, which is the difference.

This machine hit exactly that. The kernel OOM report from 2026-09-03 10:26 shows `Free swap = 0kB`
against a 7 GiB zram device, and the victim was the qemu process running a VM.

## What was changed

| Change | Value | Why |
| --- | --- | --- |
| Disk swapfile | 4 GiB on btrfs, priority 10 | Second tier behind zram, which keeps priority 100. Created with `btrfs filesystem mkswapfile`, which sets NOCOW and preallocates. |
| zram algorithm | `lzo-rle` to `zstd` | Better compression ratio, so more data fits in the same RAM. |
| `vm.swappiness` | 60 to 133 | Higher values suit compressed swap. Kept below 180 because there is now a disk tier, which is far slower. |
| `vm.page-cluster` | 3 to 0 | Swap readahead is pointless with zram: it decompresses eight pages for every fault. |
| `vm.watermark_boost_factor` | 15000 to 0 | Avoids extra reclaim driven by fragmentation rather than by memory shortage. |
| `vm.watermark_scale_factor` | 10 to 125 | Wakes kswapd earlier, so applications stall less often in direct reclaim. |
| MGLRU `min_ttl_ms` | 0 to 1000 | Stops the kernel evicting the working set of the last second. The kernel documentation gives 1000 as the value that removes janks caused by thrashing. |
| systemd-oomd on the user's `app.slice` | pressure limit 50 %, `ManagedOOMSwap=kill` | Kills one tab or the VM before the whole system stalls. |
| Chrome | Memory Saver forced to Maximum by policy | Discards inactive tabs. |
| Firefox | `browser.tabs.unloadOnLowMemory=true` | Off by default on Linux. |
| mutter `check-alive-timeout` | 5000 to 20000 ms | The "application is not responding" dialog appeared after five seconds, which is too aggressive on a machine that swaps. |

Files for each of these are in [`../tools/`](../tools).

## Daemons

`uresourced` with `cgroupify` was already installed and running. It puts every Chrome child
process in its own cgroup, which is what lets systemd-oomd kill a single tab instead of the whole
browser. Nothing to install, just do not break it.

Two were added:

* `psi-notify` sends a desktop notification when pressure rises, before anything is killed. It
  never kills.
* `earlyoom` as a last resort. One flag matters: without `-s 100` it would never fire on this
  machine, because its default condition also requires swap to be nearly full, and there are now
  10.9 GiB of it.

`nohang` was rejected because it is unmaintained in Fedora. `prelockd` and the `le9` patch were
rejected too: `le9`'s own README states that MGLRU disables its effects entirely, and this kernel
has MGLRU on.

One caveat worth recording. `min_ttl_ms` makes the kernel trigger its own OOM killer, which
bypasses systemd-oomd, cgroupify and earlyoom, and picks a victim by `oom_score`. That is how the
VM died instead of a recoverable browser tab. If that keeps happening, lower it to 500 or set it
to 0 and let the daemons decide.

## Measurements

A controlled ramp allocated memory in 256 MiB steps while sampling pressure and command latency.

| Allocated | zram used | Swapfile used | PSI full avg10 | Command latency |
| --- | --- | --- | --- | --- |
| 0 MiB | 455 MiB | 0 | 0 % | 2 ms |
| 5376 MiB | 3925 MiB | 0 | 18.5 % | 2 ms |
| 8704 MiB | 7153 MiB (full) | 93 MiB | 10.7 % | 1 ms |
| 10240 MiB | 7154 MiB (full) | 1584 MiB | 6.4 % | 1 ms |

Ten gigabytes of anonymous memory on a seven gigabyte machine. zram filled completely and the
swapfile took the rest. Latency never went above 8 ms, nothing was killed, and the desktop stayed
usable throughout. Thirty seconds after releasing it all, pressure was back to 0.3 % and 4.2 GiB
were available again.

The pages in that test were only semi-compressible, so treat the zram figures as favourable. The
point of the test was the swapfile handover, not the compression ratio.
