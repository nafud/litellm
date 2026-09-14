# Phase 2: Host hardening (RHEL 10)

Applied only after the phase 1 findings are reviewed. Apply items one at a time and
verify each before the next; keep a second SSH session open while changing SSH, SELinux
or firewall settings. The files referenced below live in `deploy/host/` in the
repository and are copied to the server with `scp` (docs/03 §3.5 describes the copy;
for this phase, `scp -r deploy/host infosec@10.50.4.68:/tmp/host` is enough).

Order matters: SELinux first (it needs a reboot and a relabel), then SSH, then firewalls.

## 2.1 SELinux: re-enable (currently Disabled)

The whole container design depends on SELinux: container-selinux confines every
container to `container_t`, and the units label their bind mounts with `:Z`. First find
out how it was disabled:

```bash
grep -E '^SELINUX=' /etc/selinux/config
grep -o 'selinux=0\|enforcing=0' /proc/cmdline || echo "no kernel argument"
rpm -q selinux-policy-targeted policycoreutils
```

Then the Red Hat procedure for a system that has been running without SELinux: go to
**permissive** first, force a full relabel at the next boot, reboot, look for denials,
then switch to enforcing.

```bash
sudo sed -i 's/^SELINUX=.*/SELINUX=permissive/' /etc/selinux/config
sudo grubby --update-kernel=ALL --remove-args="selinux=0 enforcing=0"   # only if /proc/cmdline showed them
sudo fixfiles -F onboot            # creates /.autorelabel; the relabel runs during the next boot
sudo reboot
```

After the reboot (the relabel of a 400 GB volume with little data takes a few minutes):

```bash
getenforce                          # Permissive
sudo ausearch -m AVC,USER_AVC -ts boot | tail -20   # denials since boot; expect none or only noise
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
- `devops`: keep or remove per the phase 1 answer. To remove SSH access, edit the
  `AllowUsers` line in `/etc/ssh/sshd_config` (that keyword accumulates across files, so a
  drop-in cannot narrow it) and lock the account: `sudo usermod -L -e 1 devops`.
- The stack runs under `llmgw`, created in phase 3: no password, no `sudo`, not in
  `AllowUsers`, not in `wheel`. Podman has no daemon and no root-equivalent group.

## 2.3 SSH

Confirm key login works before turning password login off:

```bash
# from the workstation
ssh -o PasswordAuthentication=no infosec@10.50.4.68 true && echo "key login OK"
```

Then, on the server:

```bash
sudo install -m 644 -o root -g root /tmp/host/10-sshd-hardening.conf /etc/ssh/sshd_config.d/10-sshd-hardening.conf
sudo sshd -t && sudo systemctl reload sshd
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|allowtcpforwarding) '
```

Open a **new** session to confirm before closing the old one. `AllowTcpForwarding local`
stays on because the admin UI is reached through `ssh -L 4000:127.0.0.1:4000` until TLS
is in place (D-10). Cipher and MAC lists come from the crypto policy
(`DEFAULT:NO-WEAKMAC:NO-SSHWEAKMACS` on this host); do not hand-edit them.

## 2.4 Updates

Depends on the package source chosen in docs/03 §3.0. Once `dnf repolist` shows
repositories:

```bash
sudo dnf -y upgrade && sudo reboot            # if a kernel or glibc update was applied
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
  reaches its sources: `chronyc sources`, because egress is filtered).
- Journal: `journalctl --disk-usage`; container logs go to the journal too
  (`LogDriver=journald`), so cap it: `SystemMaxUse=2G` in
  `/etc/systemd/journald.conf.d/size.conf`, then `sudo systemctl restart systemd-journald`.
- rsyslog listens on TCP 514 on all interfaces. If the phase 1 answer says it is not a
  deliberate log receiver, remove the `imtcp` input from `/etc/rsyslog.conf` or
  `/etc/rsyslog.d/*.conf` and `sudo systemctl restart rsyslog`; if it is deliberate,
  restrict the source in firewalld (§2.7).
- Audit rules for the files that decide who can log in, who is root and what the gateway runs:

```bash
sudo install -m 640 -o root -g root /tmp/host/llm-gateway.rules /etc/audit/rules.d/llm-gateway.rules
sudo augenrules --load && sudo auditctl -l | grep -c -E 'sshd|sudo|subid|containers|firewall|gateway'
```

## 2.6 Kernel parameters

```bash
sudo install -m 644 -o root -g root /tmp/host/90-hardening.conf /etc/sysctl.d/90-hardening.conf
sudo sysctl --system | grep -E 'rp_filter|accept_redirects|kptr_restrict|ptrace_scope'
sysctl user.max_user_namespaces net.ipv4.ip_unprivileged_port_start   # 62627 and 1024 on this host
```

`ip_forward` is left at the RHEL default: rootless Podman networks live in the service
account's own network namespace and do not route through the host. Port 4000 is above
the unprivileged-port boundary, so nothing changes there either.

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
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<zabbix-server-ip>/32" port port="10050" protocol="tcp" accept'
# only if rsyslog 514 is a deliberate receiver:
# sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<log-source-cidr>" port port="514" protocol="tcp" accept'
sudo firewall-cmd --reload && sudo firewall-cmd --list-all
```

`pmd` on 33221 gets no rule unless the phase 1 answer says it needs one. Port 4000 is
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

The network firewall currently blocks every destination from this host. Before phase 5
§5.7 (real provider call) a rule for `10.50.4.68` to the chosen provider API hosts on
TCP 443 must exist; nothing else in the deployment needs internet from the host
(images and tools arrive by `scp`).

## 2.9 Verification

- `getenforce` prints `Permissive` now and `Enforcing` after phase 4.
- `sudo sshd -T` shows `passwordauthentication no`; a fresh key login works.
- `sudo firewall-cmd --list-all` shows only the intended rich rules on `public`.
- `sudo nft list table inet llmgw_egress` shows the two chains (after phase 3).
- `sudo sysctl -a 2>/dev/null | grep -E 'rp_filter|accept_redirects|kptr_restrict'` matches the file.
- `sudo auditctl -l` lists the rules; `systemctl is-active auditd chronyd firewalld` all `active`.
- Re-run `scripts/assess.sh` and diff against the phase 1 output.
