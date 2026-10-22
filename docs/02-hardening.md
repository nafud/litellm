# Phase 2: Host hardening (RHEL 10)

Applied only after the phase 1 findings are reviewed. Apply items one at a time and
verify each before the next; keep a second SSH session open while changing SSH, SELinux
or firewall settings. The files referenced below live in `deploy/host/` in the
repository and are copied to the server with `scp` (docs/03 §3.5 describes the copy;
for this phase, `scp -r deploy/host sysadmin@192.0.2.10:/tmp/host` is enough).

Order matters: SELinux first (it needs a reboot and a relabel), then SSH, then firewalls.

Three facts from docs/01 §1.7 and §1.9 frame this phase. The infrastructure team ran
the CIS build kit on this host from the `devops` account (October 2025 and January
2026), so some settings this phase touches already exist in a CIS form: inventory them
first (docs/01 §1.10 block A) and add to what is there rather than duplicating it; the
CIS-CAT report of 2026-01-13 is the baseline to compare against. Nothing under `/etc`
is Ansible-managed, but tell the `devops` team what phase 2 changes so a future kit or
playbook run does not revert it. And the Cortex XDR agent (`traps_pmd.service`,
`/opt/traps`) is never stopped, modified or excluded from the relabel; it supports
SELinux enforcing on RHEL.

Sequence for this phase, one step per session with its verification: §2.0 hostname,
then Satellite registration (docs/03 §3.0, brought forward so that §2.4 can update the
system), §2.4 updates and the kernel reboot (§2.4.1), §2.5 logging, §2.1 audit rules and
SELinux with the relabel reboot. Done up to and including §2.4.1 on 2026-09-15.

**Deferred to after phase 5 (owner decision 2026-09-15, D-22):** §2.2/§2.3 SSH key
login and the sshd drop-in, §2.6 sysctl, §2.7 firewalld (still needs the SSH source
ranges) and §2.8 egress. None of them is a prerequisite for the deployment; SELinux,
the audit fix and rsyslog are, and they close the phase for now. Open on the XDR side:
the agent's kernel module is not loaded on the new kernel (`cytool status`: Anti
Malware and DSE "Kernel Not Supported", pmd log "KM is loaded? false", BPF collection
disabled by policy); resolved in the Cortex console, either by the content update that
adds kernel `6.12.0-211` or by enabling the Km-to-BPF fallback in the agent settings
profile. Nothing on the host changes it.

## 2.0 Hostname

The host is `localhost`. Satellite registration, the SIEM, Zabbix and the audit trail all
need a stable name. Decided (docs/01 §1.14): `llmgw01.example.org`. The name goes
into `/etc/hosts` as well so that `hostname -f` resolves before the DNS team adds the
A record (request that record now; nothing here waits for it):

Step 1, the static name (the owner chose the short form; the domain comes from step 2):

```bash
sudo hostnamectl set-hostname llmgw01
hostnamectl --static
```

Step 2, the name and domain in `/etc/hosts`, so that `hostname -f` and the Satellite see
the FQDN:

```bash
echo '192.0.2.10 llmgw01.example.org llmgw01' | sudo tee -a /etc/hosts
hostname -f; getent hosts llmgw01
sudo ausearch -k system-locale -ts recent | grep -c sethostname     # the CIS audit rule recorded the change: 1 or more
```

Expected: `hostnamectl --static` prints `llmgw01`, `hostname -f` prints
`llmgw01.example.org`, and `getent` prints `192.0.2.10`. The shell prompt shows the new name at the next login;
rsyslog and the journal use it immediately. The Zabbix agent's `Hostname=` line is not
touched: passive checks from 198.51.100.150 do not use it.

Then register to the Satellite: docs/03 §3.0, option A. Done 2026-09-15: identity under
organisation `<organisation>`, environment `Library`, `rhsm.conf` pointing at
`satellite.example.org`, BaseOS and AppStream enabled, about 300 updates pending. The
Satellite recorded the short host name (`subscription-manager` reports the kernel
hostname); rename it in the Satellite UI if the convention there is FQDNs. Continue
with §2.4.

## 2.1 SELinux: re-enable (currently Disabled)

The whole container design depends on SELinux: container-selinux confines every
container to `container_t`, and the units label their bind mounts with `:Z`. How it was
disabled is known (docs/01 §1.7, §1.11): `SELINUX=disabled` written by hand from the
`devops` account on 2026-01-07, no kernel argument, files created since unlabeled. Tell
the `devops` team it is being re-enabled, and ask why it was turned off (if it was for
the XDR agent or the CIS kit, neither needs it off).

The Red Hat procedure for a system that has been running without SELinux: go to
**permissive** first, force a full relabel at the next boot, reboot, look for denials,
then switch to enforcing. The audit rules of §2.5 are installed before this same reboot
(the CIS `99-finalize.rules` carries `-e 2`; the runtime was mutable on 2026-09-14, but
loading them here means one verification after the reboot covers both).

**Finding (2026-09-15, after the kernel reboot):** `audit-rules.service` fails at boot,
and has done so since the CIS run. `privileged.rules` is a generic CIS list; twelve of
its `-F path=` entries do not exist on this host, and one of them
(`/usr/libexec/dbus-1/dbus-daemon-launch-helper`, dbus-daemon was never installed) has
no parent directory, which the kernel rejects. `augenrules` stops at that line (79 of
81), so the rule after it and the `-e 2` lock never loaded, which is why the runtime was
still `enabled 1`. The fix is the one CIS prescribes for that control: generate the list
from the setuid/setgid binaries actually present, keeping the original file outside
`rules.d` for reference (augenrules merges every `*.rules` in that directory, so a
backup must not stay there):

```bash
sudo cp -a /etc/audit/rules.d/privileged.rules /root/privileged.rules.cis-2026-01
sudo sh -c 'find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null | sort | awk "{print \"-a always,exit -F path=\" \$1 \" -F perm=x -F auid>=1000 -F auid!=unset -k privileged\"}" > /etc/audit/rules.d/privileged.rules'
sudo diff /root/privileged.rules.cis-2026-01 /etc/audit/rules.d/privileged.rules   # host-specific list; the 12 dead paths go
sudo sh -c 'chown root:root /etc/audit/rules.d/*.rules && chmod 640 /etc/audit/rules.d/*.rules'   # CIS files are owned by devops (docs/01 §1.11); the glob must expand as root
sudo augenrules --check                                                   # "Rules have changed and should be updated"
sudo augenrules --load 2>&1 | grep -vE 'slower$'; echo "rc=${PIPESTATUS[0]}"   # no "error in line", rc=0
sudo auditctl -s | grep -E '^(enabled|failure)'                          # enabled 2: the CIS lock is now in effect
sudo auditctl -l | wc -l
```

The gateway rules (`deploy/host/llm-gateway.rules`) are **not** loaded here. Three of
their targets (`/etc/containers`, `/opt/llm-gateway`, the `llmgw` home) do not exist
before phase 3; a watch on a missing directory is installed as a plain file watch, not
the recursive directory watch intended, and a watch whose parent directory is missing
is rejected outright (first attempt on 2026-09-15: `/home/llmgw/.config/containers/`
stopped the load at line 59). They are installed at docs/04 §4.5, whose reboot loads
them.

From this point the running audit configuration is immutable (`-e 2` reached the
kernel for the first time): `auditctl` refuses changes and `audit-rules.service` keeps
its failed state until the reboot, which is the next step anyway. Every later rule
change goes into `rules.d` and needs a reboot to load.

```bash
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
grep -E '^SELINUX=' /etc/selinux/config                                  # SELINUX=permissive
sudo fixfiles -F onboot            # creates /.autorelabel; the relabel runs during the next boot
sudo reboot
```

After the reboot (the relabel of a 400 GB volume with little data takes a few minutes):

```bash
getenforce                          # Permissive
ls -Z /etc/passwd /opt /home/sysadmin                # labels instead of "?"
sudo ausearch -m AVC,USER_AVC -ts boot | tail -20   # denials since boot; expect none or only noise
systemctl is-failed audit-rules.service; sudo auditctl -s | grep -E '^enabled'   # "inactive" (one-shot, exited cleanly; "failed" is the bad answer), enabled 2
sudo /opt/traps/bin/cytool status | head -5          # XDR agent still healthy
```

**Result (2026-09-15):** relabel and second boot took about four minutes. `Permissive`,
kernel `6.12.0-211.54.1.el10_2`, labels present (`passwd_file_t`, `user_home_t`, `/opt`
as `usr_t`), no failed units, `audit-rules.service` exited cleanly with `enabled 2` (all
64 CIS rules loaded for the first time), XDR agent unchanged. Two findings:

- The only AVC denials are `syslogd_t` on `auditd_log_t` (`getattr`, `open`, `watch`,
  `ioctl` by `in:imfile`): the rsyslog imfile input of §2.5 works in permissive and
  would stop in enforcing. Resolved before the switch at docs/04 §4.5, with the SIEM
  team, by one of: the auditd `syslog` plugin (`/etc/audit/plugins.d/syslog.conf`,
  `active = yes`, `args = LOG_INFO LOG_LOCAL6`; supported path, no custom policy,
  messages tagged by the plugin instead of `tag_audit_log`), or a local policy module
  allowing `syslogd_t` read/watch on `auditd_log_t`. Recommendation: the plugin.
- rsyslog cannot reach `linux-mon.example.org:514` (connection timed out, every two
  minutes since boot; the plain `@@` action drops messages meanwhile). Nothing on the
  host changed on that path; the SIEM team must allow 192.0.2.10 to the collector.
  Whether it ever worked is unknown: the journal was volatile until today.

Leave it permissive while phase 3 installs Podman and phase 4 starts the stack, checking
`ausearch -m AVC -ts recent` after each step. Switch to enforcing once phase 4 §4.4 shows
no denials:

```bash
sudo sed -i 's/^SELINUX=.*/SELINUX=enforcing/' /etc/selinux/config
sudo setenforce 1 && getenforce     # Enforcing, no reboot needed
```

If something is denied later, read the denial rather than lowering the mode:
`sudo ausearch -m AVC -ts recent`.

## 2.2 Accounts

- Work from `sysadmin` (member of `wheel`); RHEL's default `%wheel ALL=(ALL) ALL` is enough,
  no `NOPASSWD`.
- `devops`: the Ansible automation account (keys from `ansible-control` and
  `ansible01`, `NOPASSWD:ALL`). It stays unless decided otherwise; firewalld limits
  where it can come from (§2.7). To remove SSH access instead, edit the `AllowUsers`
  line in `/etc/ssh/sshd_config` (that keyword accumulates across files, so a drop-in
  cannot narrow it) and lock the account: `sudo usermod -L -e 1 devops`.
- `sysadmin` has logged in with a password only. Install a key first (§2.3).
- The stack runs under `llmgw`, created in phase 3: no password, no `sudo`, not in
  `AllowUsers`, not in `wheel`. Podman has no daemon and no root-equivalent group.

## 2.3 SSH

Install a key for `sysadmin` and confirm key login works before turning password login
off. The workstation is Windows; its OpenSSH client has no `ssh-copy-id`, so the public
key is appended by hand (PowerShell):

```powershell
if (-not (Test-Path $env:USERPROFILE\.ssh\id_ed25519.pub)) { ssh-keygen -t ed25519 }
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh sysadmin@192.0.2.10 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh -o PasswordAuthentication=no sysadmin@192.0.2.10 true; if ($LASTEXITCODE -eq 0) { "key login OK" }
```

Protect the private key with a passphrase when `ssh-keygen` asks; it is now the only
way into the account.

Then, on the server. The CIS Build Kit already wrote most of the hardening into
`/etc/ssh/sshd_config` above the `Include` line, where it wins over every drop-in
(docs/01 §1.11); the drop-in only adds what CIS did not set (password and keyboard
authentication off, no X11 or agent forwarding, local TCP forwarding only):

```bash
sudo sh -c 'cat /etc/ssh/sshd_config.d/*.conf'    # RHEL's two drop-ins (crypto policy include, 50-redhat.conf)
sudo install -m 600 -o root -g root /tmp/host/10-sshd-hardening.conf /etc/ssh/sshd_config.d/10-sshd-hardening.conf
sudo sshd -t && sudo systemctl reload sshd
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|x11forwarding|allowagentforwarding|allowtcpforwarding|maxauthtries|allowusers) '
```

Expected: `passwordauthentication no`, `kbdinteractiveauthentication no`,
`x11forwarding no`, `allowagentforwarding no`, `allowtcpforwarding local`,
`maxauthtries 4` (CIS value, kept), `allowusers devops sysadmin`.

Open a **new** session to confirm before closing the old one. `AllowTcpForwarding local`
stays on because the admin UI is reached through `ssh -L 4000:127.0.0.1:4000` until TLS
is in place (D-10). Cipher and MAC lists come from the crypto policy
(`DEFAULT:NO-WEAKMAC:NO-SSHWEAKMACS` on this host); do not hand-edit them.

## 2.4 Updates

Depends on docs/03 §3.0 (Satellite registration). Once `dnf repolist` shows the RHEL 10
BaseOS and AppStream repositories from the capsule:

First see what the update contains, in particular the kernel and the SELinux policy
(both matter for the §2.1 reboot), then apply it. No reboot here: the §2.1 reboot boots
the new kernel. Files installed while SELinux is disabled are unlabeled, which the
relabel of §2.1 covers.

```bash
sudo dnf -q check-update | grep -E '^(kernel|selinux-policy|systemd|glibc|openssh|podman|container)'
sudo dnf upgrade                              # review the transaction summary, then y
rpm -q kernel selinux-policy-targeted | sort  # the newest kernel is installed alongside the running one
cat /etc/redhat-release
sudo dnf -q check-update | wc -l              # 0 once nothing is left
```

Result (2026-09-15, VM snapshot taken first): transaction of 300 upgrades, 8 installs
and 5 removals (the oldest kernel, `6.12.0-55.9.1.el10_0`; dnf keeps three) moved the
host from RHEL 10.1 to **10.2 (Coughlan)**. Kernels present afterwards:
`6.12.0-124.21.1.el10_1`, `6.12.0-124.28.1.el10_1` (running) and
`6.12.0-211.54.1.el10_2` (boots at the §2.1 reboot). Also upgraded: glibc 2.39-128,
openssh 9.9p1-25, systemd 257-23. `check-update` afterwards printed only two `Security:`
notices (new kernel-core installed, older kernel-core running), which is informational:
no package left to upgrade.

Automatic updates are deliberately **not** enabled (D-21). The host is patched manually
on a monthly window (docs/06 §6.8); applicable errata are visible per host in Satellite
(Hosts > Content Hosts > errata) and on the host with `sudo dnf updateinfo --summary`.
Podman is delivered through the same channel and, having no daemon, a package update
never restarts the running containers; the next container start uses the new runtime.
Container **images** are updated only deliberately (docs/06 §6.3).

### 2.4.1 Reboot into the new kernel

Kept separate from the SELinux relabel reboot (§2.1) so that a problem after either
reboot has one candidate cause (D-20, amended). Before rebooting confirm which kernel
will boot and record the XDR agent's state for comparison:

```bash
sudo grubby --default-kernel                  # /boot/vmlinuz-6.12.0-211.54.1.el10_2.x86_64
sudo /opt/traps/bin/cytool runtime query      # note the values
sudo needs-restarting -r; echo "rc=$?"        # 1 = reboot required, expected here
sudo systemctl reboot
```

After it comes back (the journal is still volatile at this point, so the previous boot's
log is gone; that is expected until §2.5):

```bash
uname -r; uptime
systemctl --failed
sudo journalctl -p err -b --no-pager | tail -n 20
sudo /opt/traps/bin/cytool status
sudo /opt/traps/bin/cytool runtime query
sudo /opt/traps/bin/cytool last_checkin
sudo subscription-manager identity
systemctl is-active sshd rsyslog chronyd zabbix-agent traps_pmd
ip -br address; chronyc tracking | grep -E '^(Reference|Leap)'
```

Expected: kernel `6.12.0-211.54.1.el10_2`, `0 loaded units listed` under `--failed`, the
XDR agent running with the same protection state as before and a fresh check-in,
identity unchanged, all five services active, `Leap status : Normal`.

## 2.5 Time, logging, audit

Order on the host: rsyslog, journal, then the audit rules of §2.1 and the reboot.

- `timedatectl` shows `System clock synchronized: yes` (chronyd is active, sources
  ntp2/ntp.example.org, `Leap status : Normal` after the kernel reboot).
- **rsyslog. Finding (2026-09-15):** `/etc/rsyslog.conf` ships `audit.log` to the SIEM
  with the legacy `$InputFile*` directives but never loads `imfile`, so rsyslog has
  rejected that block since it was written ("invalid or yet-unknown config file
  command"); `/var/lib/rsyslog/` holds only `imjournal.state`, never the `audit_log`
  state file. Syslog reached `linux-mon.example.org` all along, the audit trail did not.
  The same file runs the unused receiver on 514 (`$ModLoad imtcp`,
  `$InputTCPServerRun 514`, listening on all addresses). The file is not managed by
  Ansible (docs/01 §1.8). Fix: drop the eight legacy lines, add the input in current
  syntax as a drop-in (same tag and facility, so the SIEM parser is unchanged), keep the
  forwarding line:

```bash
sudo cp -a /etc/rsyslog.conf /root/rsyslog.conf.2026-09-15
sudo sed -i -E '/^\$(InputFileName|InputFileTag|InputFileStateFile|InputFileSeverity|InputFileFacility|InputRunFileMonitor|ModLoad imtcp|InputTCPServerRun)\b/d' /etc/rsyslog.conf
sudo diff /root/rsyslog.conf.2026-09-15 /etc/rsyslog.conf          # exactly eight lines removed
printf 'module(load="imfile")\ninput(type="imfile" File="/var/log/audit/audit.log" Tag="tag_audit_log:" Severity="info" Facility="local6")\n' | sudo tee /etc/rsyslog.d/10-audit-imfile.conf
sudo rsyslogd -N1                                                    # ends "End of config validation run. Bye."; no "invalid" lines
sudo systemctl restart rsyslog && systemctl is-active rsyslog
ss -tlnp | grep -E ':514\b'                                          # nothing
sudo ls /var/lib/rsyslog/                                            # imjournal.state plus an imfile-state: file
sudo journalctl -u rsyslog -b --no-pager | tail -n 5                # no errors
```

  The `.rpmnew` left by the upgrade only rewrites the local file actions in the new
  syntax; nothing in it is needed. For the SIEM team, not changed here: with a plain
  `@@` action, messages are dropped while the collector is unreachable (a disk-assisted
  queue on that action fixes it).

  **Superseded (2026-09-16, docs/04 §4.5, D-26):** the imfile input above was replaced
  by auditd's own syslog plugin. Two findings drove it. (1) SELinux: the policy grants
  no domain but auditd access to `auditd_log_t` beyond reading for audit tooling, has no
  boolean for rsyslog, and the denial `syslogd_t → auditd_log_t` appeared as soon as the
  input worked; the policy's path for audit events into syslog is the plugin
  (`audispd-plugins`), run by auditd in its own domain, which may send syslog messages.
  (2) Routing: with facility `local6` at severity `info` the records also matched the
  `*.info` selector of `/var/log/messages`; 173 590 audit lines had landed there in one
  day. Now: `local6.none` on that selector, `active = yes` and `args = LOG_INFO LOG_LOCAL6`
  in `/etc/audit/plugins.d/syslog.conf`, the drop-in removed, and a per-unit
  `LogRateLimitIntervalSec=0` for `auditd.service` so journald never drops records on
  the way to rsyslog (`deploy/host/auditd-log-ratelimit.conf`). Facility and severity
  are unchanged for the SIEM; the syslog tag becomes `audisp-syslog` instead of
  `tag_audit_log` (SIEM team informed). Also removed: `/etc/logrotate.d/audit` (CIS kit,
  unowned), which rotated the audit log daily in parallel with auditd's own rotation and
  was denied `unlink` on `auditd_log_t`; auditd rotates by `max_log_file` /
  `num_logs` (backup `/root/logrotate-audit.cis-2026-01`).
- **Journal:** volatile on this host (`/var/log/journal` absent, docs/01 §1.11), so every
  reboot discards it, including the boot that just happened. Container logs go to the
  journal (`LogDriver=journald`) and so do the `llmgw` user's units; make it persistent
  and capped:

```bash
sudo install -d -m 755 -o root -g root /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\nSystemMaxUse=2G\n' | sudo tee /etc/systemd/journald.conf.d/llm-gateway.conf
sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald && journalctl --disk-usage && ls -ld /var/log/journal
```

- **Audit:** the CIS rule set is in `rules.d`, but `privileged.rules` stops the load at
  boot (finding in §2.1, where the fix and the gateway rules are applied). Verify after
  the reboot; `enabled 2` means the configuration is immutable and any later change
  needs a reboot:

```bash
systemctl is-failed audit-rules.service              # inactive (one-shot unit; "failed" is the bad answer)
sudo auditctl -s | grep -E '^(enabled|pid|lost)'     # enabled 2
```

  The gateway watches (`llm-gateway.rules`) follow in docs/04 §4.5, once their targets
  exist.

- sudo: CIS left the defaults; `Defaults use_pty` and `Defaults logfile=/var/log/sudo.log`
  are optional additions (the SIEM already receives `authpriv`).

## 2.6 Kernel parameters

The CIS Build Kit already installed `/etc/sysctl.d/60-{fs,ipv4,ipv6,kernel}_sysctl.conf`
(docs/01 §1.11). `90-hardening.conf` adds only the missing keys (`kptr_restrict`,
`unprivileged_bpf_disabled`, `fs.protected_*`, `default.rp_filter`):

```bash
sudo install -m 644 -o root -g root /tmp/host/90-hardening.conf /etc/sysctl.d/90-hardening.conf
sudo sysctl --system | grep -E 'kptr_restrict|protected_regular|default.rp_filter|unprivileged_bpf'
sysctl user.max_user_namespaces net.ipv4.ip_unprivileged_port_start net.ipv4.conf.all.forwarding   # 62627, 1024, 0
```

Forwarding stays off (CIS sets it, and rootless Podman networks live in the service
account's own network namespace, not routed through the host). Port 4000 is above the
unprivileged-port boundary, so nothing changes there either. The CIS module blacklists
(`sctp`, `tipc`, `can`, `l2tp*`, `usb-storage`) do not touch anything Podman needs
(`overlay`, `bridge`, `veth`, `tun` are not in them).

## 2.7 Inbound: firewalld (currently not running)

A port published by a rootless container is an ordinary listening socket owned by
`llmgw`, so firewalld's rules apply to it exactly as to any other service. Enabling
firewalld with the stock `public` zone keeps SSH allowed, so this is safe to do from an
SSH session; everything else is then narrowed explicitly. Values in angle brackets come
from the phase 1 answers.

```bash
sudo systemctl enable --now firewalld
sudo firewall-cmd --get-default-zone                    # public
sudo firewall-cmd --permanent --zone=public --remove-service=cockpit
sudo firewall-cmd --permanent --zone=public --remove-service=dhcpv6-client
sudo firewall-cmd --permanent --zone=public --remove-service=ssh
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<admin-cidr>" service name="ssh" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<ansible-cidr>" service name="ssh" accept'
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="198.51.100.150/32" port port="10050" protocol="tcp" accept'
# only if rsyslog 514 is a deliberate receiver:
# sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<log-source-cidr>" port port="514" protocol="tcp" accept'
sudo firewall-cmd --reload && sudo firewall-cmd --list-all
```

*2026-09-17:* firewalld is enabled in docs/08 §8.3 (WAF exposure) with the `ssh` service
left in the zone, because the admin ranges are still unknown; the two SSH rich rules
below and the removal of the `ssh` service are applied when they are. The Zabbix rule
is part of §8.3 so that enabling firewalld does not break monitoring.

`<admin-cidr>` and `<ansible-cidr>` come from docs/01 question 5 (logins seen from
198.51.100.19 and 198.51.100.2 for `sysadmin`, 198.51.100.50 and 198.51.100.60 for `devops`).
The Cortex XDR agent on 33221 gets no rule unless its administrators say it needs one
(docs/01 §1.8 block D shows whether it even binds a non-loopback address). Port 4000 is
not opened in this phase: LiteLLM listens on `127.0.0.1` until validation is complete
(docs/05 §5.10 opens it for the client subnet).

## 2.8 Outbound: egress policy for the service account

Rootless Podman sends all container traffic through `pasta`, a process owned by `llmgw`,
so the host can attribute every outbound packet of the stack to that uid. The ruleset
in `deploy/host/llmgw-egress.nft` allows `llmgw` only established traffic, loopback, DNS
to 198.51.100.53/198.51.100.54 and TCP 443; everything else from that uid is logged and
dropped. It is a separate nftables table that coexists with firewalld (which manages
only its own table). Apply it **after** phase 3 has created the `llmgw` user (nft
resolves the name at load time):

```bash
sudo install -m 644 -o root -g root /tmp/host/llmgw-egress.nft /etc/nftables/llmgw-egress.nft
sudo nft -c -f /etc/nftables/llmgw-egress.nft            # syntax check, applies nothing
echo 'include "/etc/nftables/llmgw-egress.nft"' | sudo tee -a /etc/sysconfig/nftables.conf
sudo systemctl enable --now nftables
sudo nft list table inet llmgw_egress
```

The host has general internet access. This table is what keeps the gateway's own
traffic within the architecture's "provider APIs only" intent at the host level: the
service account, and therefore every container, can reach only TCP 443 (plus DNS to
the two resolvers). Root keeps unrestricted egress for `dnf`, registration and the image
pulls of docs/03 §3.7 run as `llmgw`, which is TCP 443 as well. Once the provider is
chosen (D-19), the `tcp dport 443 accept` rule can be narrowed to a named set of the
provider's addresses, or the network firewall can restrict `192.0.2.10` to those hosts;
neither is needed to bring the stack up.

## 2.9 Verification

- `getenforce` prints `Permissive` now and `Enforcing` after phase 4.
- `sudo sshd -T` shows `passwordauthentication no`; a fresh key login works.
- `sudo firewall-cmd --list-all` shows only the intended rich rules on `public`.
- `sudo nft list table inet llmgw_egress` shows the two chains (after phase 3).
- `sudo sysctl -a 2>/dev/null | grep -E 'rp_filter|accept_redirects|kptr_restrict'` matches the file.
- `sudo auditctl -l` lists the rules; `systemctl is-active auditd chronyd firewalld` all `active`.
- Re-run `scripts/assess.sh` and diff against the phase 1 output.
