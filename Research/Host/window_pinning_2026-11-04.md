# Per-VM pinned windows, 2.15.5

Always on Top now belongs to the existing canonical-machine window-state
record alongside frame, rotation and panel size. Menu changes save immediately.
New windows restore their level before they appear, and the menu's initial
checkmark follows the restored level. A record without the new Boolean decodes
as unpinned while retaining its original geometry. Full-screen transitions keep
the logical preference; minimizing retains the last ordinary frame so a pin
change from another tool window can still be saved.

The menu explicitly targets its VM's window controller. Preferences stay in
the host's `com.vphone.vm-window-state` suite; there is no write into a running
machine folder and no guest or firmware patch change.

Complete VPhone and Release Launchpad builds passed. Forty-two selected
CoreKit tests across window-state, orientation and geometry suites passed,
including per-VM true/false isolation and records without the pinning field.
All 39 staged guest-resource files are byte-identical to 2.15.4, so the existing
machines keep that guest environment and only change host-bundle bindings.

The installed host bundle is `2.15.5-local.0c69a4eb`. Its policy, AMFI preflight
and signature checks passed. A native menu click saved `alwaysOnTop=true`;
after a complete Duo stop/start the saved frame, rotation and panel record
were unchanged and WindowServer reported layer 3 for the new process.

A second native menu click disabled pinning. A full stop/start then restored
the unchanged record with `alwaysOnTop=false` and actual layer 0. Finally the
original enabled preference was restored through the menu and saved. Duo is
left running, pinned, in its original cover pose; iPad remains stopped.
