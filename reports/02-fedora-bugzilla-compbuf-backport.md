# Red Hat Bugzilla report: amdgpu backport request

**Submit at:** https://bugzilla.redhat.com/enter_bug.cgi?product=Fedora
**Product:** Fedora · **Version:** 44 · **Component:** kernel · **Severity:** low

---

## Summary

Please backport upstream commit 251a01d34b44 ("drm/amd/display: fix compressed buffer config routine waiting time") to the Fedora 7.1.x/7.2.x kernels, because DCN 3.1 hardware hits a WARNING on every modeset

## Description of problem

On every boot and on most modesets, amdgpu logs a REG_WAIT timeout followed by a WARNING backtrace on an AMD Radeon 610M (Mendocino, DCN 3.1.6):

```
amdgpu 0000:03:00.0: [drm] REG_WAIT timeout 1us * 100 tries - dcn31_program_compbuf_size line:142
WARNING: drivers/gpu/drm/amd/amdgpu/../display/dc/hubbub/dcn31/dcn31_hubbub.c:151 at dcn31_program_compbuf_size+0xd0/0x220 [amdgpu], CPU#5: KMS thread/1210
Call Trace:
 dcn20_optimize_bandwidth+0xee/0x250 [amdgpu]
 dc_commit_state_no_check+0x91c/0xf00 [amdgpu]
 dc_commit_streams+0x362/0x780 [amdgpu]
 amdgpu_dm_commit_streams+0x563/0x7c0 [amdgpu]
 amdgpu_dm_atomic_commit_tail+0xd1/0xd20 [amdgpu]
 commit_tail+0xb0/0x150
 drm_atomic_helper_commit+0x158/0x1a0
 drm_atomic_commit+0xb1/0xe0
 drm_mode_atomic_ioctl+0x77f/0x8b0
 amdgpu_drm_ioctl+0x4a/0x80 [amdgpu]
```

The kernel is left `Tainted: [W]`. The driver waits only 1 us x 100 tries for the DET to shrink, programs COMPBUF anyway, the hardware raises CONFIG_ERROR, and the resulting `ASSERT` becomes a `WARN_ON_ONCE`.

## Version-Release number

`kernel-core-7.1.12-200.fc44.x86_64` (also reproduced conceptually on 7.1.13 and 7.2.x, since the old code is still present in those trees).

## How reproducible

Every boot, and reliably when the internal panel is disabled and only an external HDMI output is active (laptop used with the lid closed).

## Additional info

* Introduced in 7.0 by commit `592c5b80110d` ("drm/amd/display: Migrate HUBBUB register access from hwseq to hubbub component"), bisected by the CachyOS community.
* Fixed upstream by `251a01d34b44` ("drm/amd/display: fix compressed buffer config routine waiting time"), which switches to `dcn31_wait_for_det_apply()` with a 1000 us x 30 wait. It landed in v7.3-rc1 only, and carries no `Fixes:` or `Cc: stable` tag, so it will not reach 7.1.x/7.2.x automatically.
* Mendocino (DCN 3.1.6) builds its hubbub with `hubbub31_construct()`, so it is affected and the fix applies.
* Impact is cosmetic to mild: the fix author describes "unstable video output, specifically after resuming from screen sleep. The video may not come back at all or may come up partly messed up". No system instability was attributed to it on this machine.

This is filed separately from, and is **not** the cause of, the spontaneous hardware resets reported in the companion bug.

### References

* Fix: https://lore.kernel.org/all/20260604145428.809959-24-aurabindo.pillai@amd.com/
* RFC/discussion: https://lore.kernel.org/all/20260519144509.2646680-1-antonio@mandelbit.com/
* Bisect and reports: https://github.com/CachyOS/linux-cachyos/issues/810 · https://lore.kernel.org/all/20260316094232.6bb6f0bf@schienar/
* Related Fedora bug: https://bugzilla.redhat.com/show_bug.cgi?id=2499646

### Attachments

`dmesg-boot0.txt`, `paquetes.txt`, `lspci-vvnn.txt`


---

All logs, the full boot table and the stress test results are published at
https://github.com/alx-mp/acer-a314-23p-sync-flood
