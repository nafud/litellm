# Phase 2: Host hardening (RHEL 10)

Applied only after the phase 1 findings are reviewed. Apply items one at a time and
verify each before the next; keep a second SSH session open while changing SSH, SELinux
or firewall settings. The files referenced below live in `deploy/host/` in the
repository and are copied to the server with `scp` (docs/03 §3.5 describes the copy;
for this phase, `scp -r deploy/host infosec@10.50.4.68:/tmp/host` is enough).

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
system), §2.4 updates, §2.5 logging and audit rules, §2.1 SELinux with the one reboot
that also boots the updated kernel and relabels, then §2.2, §2.3 SSH, §2.6, §2.7, §2.8.

## 2.0 Hostname

The host is `localhost`. Satellite registration, the SIEM, Zabbix and the audit trail all
need a stable name. Decided (docs/01 §1.14): `xbbovsrlllm001.xalqbank.az`. The name goes
into `/etc/hosts` as well so that `hostname -f` resolves before the DNS team adds the
A record (request that record now; nothing here waits for it):

Step 1, the static name (the owner chose the short form; the domain comes from step 2):

```bash
sudo hostnamectl set-hostname xbbovsrlllm001
hostnamectl --static
```

Step 2, the name and domain in `/etc/hosts`, so that `hostname -f` and the Satellite see
the FQDN:

```bash
echo '10.50.4.68 xbbovsrlllm001.xalqbank.az xbbovsrlllm001' | sudo tee -a /etc/hosts
hostname -f; getent hosts xbbovsrlllm001
sudo ausearch -k system-locale -ts recent | grep -c sethostname     # the CIS audit rule recorded the change: 1 or more
```

Expected: `hostnamectl --static` prints `xbbovsrlllm001`, `hostname -f` prints
`xbbovsrlllm001.xalqbank.az`, and `getent` prints `10.50.4.68`. The shell prompt shows the new name at the next login;
rsyslog and the journal use it immediately. The Zabbix agent's `Hostname=` line is not
touched: passive checks from 10.100.7.150 do not use it.

Then register to the Satellite: docs/03 §3.0, option A. Done 2026-09-15: identity under
organisation `XALQ_BANK_OSJ`, environment `Library`, `rhsm.conf` pointing at
`satellite.xalqbank.az`, BaseOS and AppStream enabled, about 300 updates pending. The
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
loading them here means one verification after the reboot covers both):

```bash
sudo install -m 640 -o root -g root /tmp/host/llm-gateway.rules /etc/audit/rules.d/llm-gateway.rules
sudo chown root:root /etc/audit/rules.d/*.rules && sudo chmod 640 /etc/audit/rules.d/*.rules   # CIS files are owned by devops (docs/01 §1.11)
sudo augenrules --check                                                   # "Rules have changed and should be updated"
sudo augenrules --load && sudo auditctl -l | grep -c -E 'sshd|subid|containers|firewall|gateway'   # 10 (runtime is mutable, docs/01 §1.13)
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
grep -E '^SELINUX=' /etc/selinux/config                                  # SELINUX=permissive
sudo fixfiles -F onboot            # creates /.autorelabel; the relabel runs during the next boot
sudo reboot
```

After the reboot (the relabel of a 400 GB volume with little data takes a few minutes):

```bash
getenforce                          # Permissive
ls -Z /etc/passwd /opt /home/infosec                # labels instead of "?"
sudo ausearch -m AVC,USER_AVC -ts boot | tail -20   # denials since boot; expect none or only noise
sudo auditctl -l | grep -c -E 'sshd|subid|containers|firewall|gateway'   # 10: the new rules loaded
sudo /opt/traps/bin/cytool status | head -5          # XDR agent still healthy
```

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

- Work from `infosec` (member of `wheel`); RHEL's default `%wheel ALL=(ALL) ALL` is enough,
  no `NOPASSWD`.
- `devops`: the Ansible automation account (keys from `ansible-control` and
  `xbbovsransb001`, `NOPASSWD:ALL`). It stays unless decided otherwise; firewalld limits
  where it can come from (§2.7). To remove SSH access instead, edit the `AllowUsers`
  line in `/etc/ssh/sshd_config` (that keyword accumulates across files, so a drop-in
  cannot narrow it) and lock the account: `sudo usermod -L -e 1 devops`.
- `infosec` has logged in with a password only. Install a key first (§2.3).
- The stack runs under `llmgw`, created in phase 3: no password, no `sudo`, not in
  `AllowUsers`, not in `wheel`. Podman has no daemon and no root-equivalent group.

## 2.3 SSH

Install a key for `infosec` and confirm key login works before turning password login
off. The workstation is Windows; its OpenSSH client has no `ssh-copy-id`, so the public
key is appended by hand (PowerShell):

```powershell
if (-not (Test-Path $env:USERPROFILE\.ssh\id_ed25519.pub)) { ssh-keygen -t ed25519 }
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh infosec@10.50.4.68 "mkdir -p ~/.ssh && chmod 700 ~/.ssh && cat >> ~/.ssh/authorized_keys && chmod 600 ~/.ssh/authorized_keys"
ssh -o PasswordAuthentication=no infosec@10.50.4.68 true; if ($LASTEXITCODE -eq 0) { "key login OK" }
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
`maxauthtries 4` (CIS value, kept), `allowusers devops infosec`.

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
sudo dnf -y install dnf-automatic
sudo sed -i -e 's/^upgrade_type = .*/upgrade_type = security/' -e 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic.timer
```

Podman is delivered through the same channel and receives security fixes there; because
it has no daemon, a package update never restarts the running containers. Container
**images** are updated only deliberately (docs/06 §6.3). If the package source is an
ISO or a one-off RPM bundle, there are no automatic updates: schedule a monthly manual
refresh instead and record it.

## 2.5 Time, logging, audit

- `timedatectl` shows `System clock synchronized: yes` (chronyd is active; confirm it
  reaches its sources: `chronyc sources`).
- Journal: it is volatile on this host (`/var/log/journal` does not exist, docs/01
  §1.11), so every reboot discards it. Container logs go to the journal
  (`LogDriver=journald`) and so do the `llmgw` user's units; make it persistent and
  capped:

```bash
sudo install -d -m 755 -o root -g root /etc/systemd/journald.conf.d
printf '[Journal]\nStorage=persistent\nSystemMaxUse=2G\n' | sudo tee /etc/systemd/journald.conf.d/llm-gateway.conf
sudo mkdir -p /var/log/journal && sudo systemd-tmpfiles --create --prefix /var/log/journal
sudo systemctl restart systemd-journald && journalctl --disk-usage && ls -ld /var/log/journal
```

  rsyslog keeps forwarding to the SIEM through `imjournal` regardless.
- rsyslog forwards everything to the SIEM (`*.* @@linux-mon.xalqbank.az`) and ships
  `audit.log` through `imfile`; both stay, and container logs reach the SIEM through
  `imjournal`. It also runs an unused receiver (`$ModLoad imtcp`,
  `$InputTCPServerRun 514`). Unless the SIEM team wants this host to relay, remove those
  two lines (in the playbook if Ansible owns the file, docs/01 §1.8 block B), then
  `sudo rsyslogd -N1 && sudo systemctl restart rsyslog` and confirm `ss -tlnp` no longer
  shows 514. If it stays, restrict the source in firewalld (§2.7).
- Audit: the CIS rule set is in place (`50-*.rules`, `privileged.rules`, docs/01
  §1.11) with `-e 2` in `99-finalize.rules`. The gateway rules and the ownership fix
  (CIS files owned by `devops`) were loaded in §2.1. Verify after the reboot, and note
  the `enabled` value: `2` means the boot made the configuration immutable and any
  later audit change needs another reboot:

```bash
sudo auditctl -s | grep -E '^(enabled|pid|lost)'
sudo auditctl -l | grep -E 'gateway|firewall|subid'
sudo stat -c '%U:%G %a %n' /etc/audit/rules.d/*.rules      # root:root 640
```

- sudo: stock `Defaults`; sudo events already reach the SIEM via authpriv. Optional CIS
  items, not needed by the deployment: `Defaults use_pty` and
  `Defaults logfile="/var/log/sudo.log"` in `/etc/sudoers.d/10-logging` (`visudo -cf`
  before installing); the CIS audit watch on `/var/log/sudo.log` only makes sense with
  the second one.

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
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="10.100.7.150/32" port port="10050" protocol="tcp" accept'
# only if rsyslog 514 is a deliberate receiver:
# sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<log-source-cidr>" port port="514" protocol="tcp" accept'
sudo firewall-cmd --reload && sudo firewall-cmd --list-all
```

`<admin-cidr>` and `<ansible-cidr>` come from docs/01 question 5 (logins seen from
10.240.234.19 and 10.50.12.2 for `infosec`, 10.100.8.50 and 10.100.7.60 for `devops`).
The Cortex XDR agent on 33221 gets no rule unless its administrators say it needs one
(docs/01 §1.8 block D shows whether it even binds a non-loopback address). Port 4000 is
not opened in this phase: LiteLLM listens on `127.0.0.1` until validation is complete
(docs/05 §5.10 opens it for the client subnet).

## 2.8 Outbound: egress policy for the service account

Rootless Podman sends all container traffic through `pasta`, a process owned by `llmgw`,
so the host can attribute every outbound packet of the stack to that uid. The ruleset
in `deploy/host/llmgw-egress.nft` allows `llmgw` only established traffic, loopback, DNS
to 10.100.0.1/10.100.0.2 and TCP 443; everything else from that uid is logged and
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
provider's addresses, or the network firewall can restrict `10.50.4.68` to those hosts;
neither is needed to bring the stack up.

## 2.9 Verification

- `getenforce` prints `Permissive` now and `Enforcing` after phase 4.
- `sudo sshd -T` shows `passwordauthentication no`; a fresh key login works.
- `sudo firewall-cmd --list-all` shows only the intended rich rules on `public`.
- `sudo nft list table inet llmgw_egress` shows the two chains (after phase 3).
- `sudo sysctl -a 2>/dev/null | grep -E 'rp_filter|accept_redirects|kptr_restrict'` matches the file.
- `sudo auditctl -l` lists the rules; `systemctl is-active auditd chronyd firewalld` all `active`.
- Re-run `scripts/assess.sh` and diff against the phase 1 output.
