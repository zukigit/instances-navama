# How the modes work

This page explains what Terraform and the VM do in each situation: run periods (`run_hours`, `run_hours_mode`), access keys (`access_keys`), boots, IP changes and the SSH rule. The [README](README.md) covers setup and usage.

## The one rule

**A period ends only at its end time.** A period is the time between a start and the scheduled shutdown. At the start of every period, each access key's data usage goes back to 0 and its `ss://` link stays the same. Nothing else resets usage: not a reboot, not a key change, not a mode change.

The period's end is saved on the VM in `/var/lib/outline-period/end`. Both the timer step and the boot script read and write it.

## The parts

| Part | Where it runs | Runs when | Does |
|---|---|---|---|
| `google_compute_instance.outline` | GCP | Created once per region; `desired_status = "RUNNING"` makes every `apply` start a stopped VM | Metadata changes, such as the boot script, update the VM in place |
| Boot script (`startup.sh.tftpl`) | VM, as root | **Every boot**, however the VM was started | Continues the period or starts a new one; updates Outline's IP |
| `terraform_data.outline_install` (`postscript.sh`) | VM, over SSH | VM is new (once per VM; skipped if Outline is already running) | Installs Docker and Outline. The installer also creates one unnamed key, which the keys sync deletes |
| `terraform_data.shutdown_timer` (`shutdown-timer.sh`) | VM, over SSH | VM is new, or `run_hours` or `shutdown-timer.sh` changed | Sets the period: its end, plus the usage resets |
| `terraform_data.access_keys` (`access-keys.sh sync`) | VM, over SSH | Only if `access_keys` is set; VM is new, or `access_keys` or `access-keys.sh` changed | Creates, deletes and sets limits on keys, and prints the links. **Never changes usage** |
| `terraform_data.access_keys_off` | VM, over SSH | Only if `access_keys` is empty: once per VM, and again whenever `access_keys` is emptied | Cancels usage resets left by earlier appends |
| `terraform_data.ssh_close` | Your PC (`gcloud`) | Any SSH step above ran | Closes port 22 |
| `outline-usage-reset-<time>.timer` | VM, systemd | At `<time>`, or at the next boot if the VM was off then | Resets usage to 0 (set up by `append`) |

**Order in one apply:** VM → install → period → keys (or keys off) → close SSH.

**SSH uses the VM's current IP.** Right after Terraform starts a stopped VM, its state can show an empty external IP, so `data.google_compute_instance.current` reads the VM again during the apply. The SSH steps and `terraform output` use that IP.

**Only one key operation runs at a time** on the VM, enforced by a lock: the usage reset at boot, a missed reset timer, the timer step's reset and the keys sync. So they never change the same keys at once. The keys sync also waits for the boot script to finish, so the links it prints already have the new IP after a restart.

**`run_hours_mode` is not a trigger.** It only says *how* a `run_hours` change is applied, so switching the mode alone does nothing. To act again with the same values, use `-replace='terraform_data.shutdown_timer["<region>"]'`.

**If nothing changed**, a plain `apply` does nothing on the VM. The exception is a stopped VM, which gets started, and then the [boot](#boot) logic applies.

## Modes at a glance

When `run_hours` changes, or the timer step is forced with `-replace`, on a running VM:

| | Period end (shutdown) | Data usage | Keys and links |
|---|---|---|---|
| **`reset`** | now + `run_hours` | 0 **now** | Unchanged |
| **`append`** | current end + `run_hours` (now + `run_hours` if no period is running) | Unchanged until the **current end**, then 0 | Unchanged |
| **`run_hours = 0`, `reset`** | none (shutdown cancelled) | 0 now | Unchanged |
| **`run_hours = 0`, `append`** | none (shutdown cancelled) | 0 at the current end | Unchanged |

When `access_keys` changes, in any mode: keys are synced by name (see [Access keys](#access-keys)), and usage and the period are untouched.

## `reset` mode

Starts a new period now.

1. Pending usage resets from earlier `append`s are cancelled.
2. Every key's usage goes to 0 now. Each key is recreated with the same password, port and limit, so the link stays the same.
3. The end is set to now + `run_hours`, replacing the old end.

```
day 0   apply reset, run_hours=720   -> usage 0 now, VM stops day 30
```

## `append` mode

Extends the current period. Nothing changes for users until the current end; then a new period starts.

1. The current end is read as T1.
2. A usage reset is scheduled for T1 (a systemd timer).
3. The end is set to T1 + `run_hours` (T2).

Example: the period ends tomorrow at 10:00 (T1), alice has 50 GB left of 200 GB, and you append 720 h:
```
now              apply append 720h -> alice still has 50 GB left; end moves to T1 + 30 days (T2)
tomorrow 10:00   T1: usage reset    -> alice has 200 GB again, same link; VM keeps running
T2               VM stops
```
Appending twice before T1 schedules resets at T1 and T2, and the end becomes T3. Each old end is a period boundary.

## Access keys

The keys step runs when `access_keys` changes, or on a new VM. It runs the same way in both modes and matches keys by name:

| On the server | Result |
|---|---|
| Name in `access_keys`, key exists | Same key and link; limit set from `access_keys`; usage unchanged |
| Name in `access_keys`, no key, but it was lost in a failed usage reset | Created again from the backup: same link (`restored, same link`) |
| Name in `access_keys`, no key | New key, printed as `NEW link` |
| Key not in `access_keys`, including keys made in Manager, or a duplicate name | Deleted |

It prints every key's link. With `access_keys = {}` (the default), Terraform doesn't touch keys and no usage resets happen: `access_keys_off` cancels any left over from earlier appends.

**How a usage reset works:** Outline counts usage per key ID and has no "reset" call. So each key is deleted and created again with the same name, password, port and limit. The link holds only the password, host and port, so it doesn't change, and the new ID starts at 0. Every key on the server is reset, including keys made in Manager, but with `access_keys` set those are deleted anyway.

**If recreating a key fails**, the reset tries to bring it back from its backup (same link) a few times, then carries on with the other keys. If it still can't, the reset stops there, so at most one key is missing and the rest are left as they were. The backup (with the key passwords) stays in `/var/lib/outline-access-keys/` until the key is back. The key comes back with the same link at the next usage reset (each reset first restores keys an earlier one left missing), at the next keys sync (any `apply` that changes `access_keys`), or when you run `sudo outline-access-keys restore` on the VM. After a successful sync the backups are deleted, so a key you removed from `access_keys` can't come back later.

**One reset at a time is enough:** a reset within 5 minutes of the last one is skipped. A new period at boot and a missed reset timer can both fire right after a boot, and this gives users one disconnect instead of two.

## Boot

The boot script runs at every boot, however the VM was started: `apply`, `gcloud`, the Console, a reboot or a crash.

1. **The period** (only if `run_hours > 0`):
   - **The saved end is still ahead** (a reboot or stop mid-period): the period continues, and the VM shuts down at the saved end. Appended time is kept, and pending usage resets still fire at their times.
   - **The saved end has passed** (the VM was off when the period ended): a **new period** of `run_hours` starts now, pending resets are cancelled, and usage goes to 0.
   - **No saved end** (a new VM, or a VM set up before this existed): a new period starts now, without a usage reset.
2. **The IP:** if the external IP changed, the boot script tells Outline the new IP and updates `access.txt`. **Every link changes** because the IP is part of it, so users need their new link. Usage isn't affected.
3. **Missed usage resets:** a reset timer whose time passed while the VM was off runs right after boot.

**Off time counts toward the period.** If the VM is stopped at day 10 of 30 and started at day 15, it still stops at day 30.

## Started by this apply

When an apply starts a stopped VM (or creates one), the boot script has already run before the timer step:

- **The boot started a new period:** the timer step uses that period and sets the end to now + `run_hours`. It doesn't reset usage again, and in `append` mode it doesn't add `run_hours` on top.
- **The boot continued the period:** the timer step does exactly what the mode says, as on a running VM.

The timer step tells these apart by comparing the VM's boot time with the plan time (`plantimestamp()`), and by the marker `/run/outline-period/boot` that the boot script leaves, which says `new` or `continue`.

## Common situations

| Situation | What to do | Result |
|---|---|---|
| First setup | Set `run_hours` and `access_keys`, then `apply` | VM, Outline, keys and links printed, period started |
| The timer stopped the VM; start the next period | plain `apply` | VM starts, new period, usage 0, same links (unless the IP changed) |
| Start a new period now on a running VM | Change `run_hours`, or `-replace` the timer step, in `reset` mode | Usage 0 now, end = now + `run_hours` |
| Extend before the period ends | `append` mode, then change `run_hours` or `-replace` the timer step | See [`append` mode](#append-mode) |
| Add a user, change a limit, or remove a user | Edit `access_keys`, then `apply` (any mode) | Only that key changes; nobody's usage resets |
| Give one user a new link (leaked key) | Rename their entry in `access_keys`, then `apply` | Old key deleted, new key and link |
| Stop managing keys | `access_keys = {}`, then `apply` | Keys stay on the server, untouched from now on; pending usage resets are cancelled |
| No time limit | `run_hours = 0` | Shutdown cancelled; usage only resets as per the mode at that apply |

## Things that can surprise you

- **A plain `apply` uses `terraform.tfvars`.** If the last apply used `-var='run_hours=24'` and `terraform.tfvars` says `720`, the next plain apply sees `run_hours` change back and applies it in the mode from `terraform.tfvars`. In `reset` mode that resets everyone's usage now. Keep `run_hours` and `run_hours_mode` in `terraform.tfvars`.
- **Editing `shutdown-timer.sh` re-runs the timer step** in the current mode: `reset` resets usage now, and `append` adds `run_hours` again. Editing `access-keys.sh` only re-syncs the keys, which is harmless. Editing `postscript.sh` doesn't affect existing VMs; replace a VM to reinstall it.
- **A new VM** always starts a fresh period with fresh keys, whatever the mode.
- **During a usage reset**, connected users drop for a moment, keys are briefly missing, Manager shows new key IDs, and Manager loses the earlier usage history.
- **Outline counts usage over a rolling 30 days.** Without a reset, usage older than 30 days drops off on its own.
- **A failed timer step in `append` mode:** if the step fails after it has already moved the end (for example, the SSH connection drops at the very end), Terraform re-runs it on the next apply and appends `run_hours` again. Check the end on the VM (see [Checking the state](#checking-the-state-on-a-vm)) before re-applying after such a failure.
- **`sudo shutdown -c` on the VM** cancels the shutdown but not the saved end. A VM that keeps running past its end gets no new period, and no usage reset, until the next `apply` that changes `run_hours` or uses `-replace`. A later boot then starts a new period, because the end has passed.
- **Outline's ports** (`outline_api_port`, `outline_keys_port`) are set at install, so changing them later doesn't affect an existing VM. `plan` stops if the firewall ports don't include them.
- **Port 22:** each SSH step opens the `<firewall_name>-ssh` rule first, and `ssh_close` closes it at the end. If a step fails, the rule stays open until the next successful apply. If `default-allow-ssh` is enabled, it keeps port 22 open regardless.

## Checking the state on a VM

```bash
date -d @$(sudo cat /var/lib/outline-period/end)     # current period end
cat /run/outline-period/boot                         # this boot: new or continue
sudo cat /run/systemd/shutdown/scheduled             # pending shutdown (USEC = epoch µs)
systemctl list-timers 'outline-usage-reset-*'        # pending usage resets
sudo journalctl -u google-startup-scripts -b         # boot script log (period, IP)
sudo journalctl -u 'outline-usage-reset-*'           # usage reset log
sudo outline-access-keys restore                     # bring back a key lost in a failed usage reset
```
