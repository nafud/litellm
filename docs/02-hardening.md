# Phase 2: Host hardening (RHEL 10)

Applied only after the phase 1 report is reviewed. Each item is marked in the review as
**required**, **already in place**, or **not applicable**. Apply items one at a time and
verify each before the next; keep a second SSH session open while changing SSH or
firewall rules. The files referenced below live in `deploy/host/` so that what runs on
the server is what is reviewed in the repository.

The host is RHEL 10.1 with SELinux, firewalld and chrony as shipped. Hardening keeps all
three and adds to them; nothing here disables a Red Hat default.

## 2.1 Accounts

- Work from the named admin account (`infosec`, member of `wheel`), never from `root`.
  RHEL's default `%wheel ALL=(ALL) ALL` sudo rule is enough; no `NOPASSWD`.
- Lock accounts the report shows as unused: `sudo usermod -L -e 1 <user>`.
- No account with an empty password (report section 3).
- The stack runs under a dedicated, unprivileged service account `llmgw` created in
  phase 3: no password, no `sudo`, no SSH login, no membership in `wheel`. There is no
  root-equivalent group to avoid (Podman has no daemon and no socket).

## 2.2 SSH

```bash
sudo install -m 644 -o root -g root /opt/llm-gateway/repo/deploy/host/10-sshd-hardening.conf /etc/ssh/sshd_config.d/10-sshd-hardening.conf
sudo sshd -t && sudo systemctl reload sshd
sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|kbdinteractiveauthentication|allowusers|allowtcpforwarding) '
```

Confirm from a **new** session that key login still works before closing the old one.
`AllowTcpForwarding local` stays on because the admin UI is only reachable through
`ssh -L 4000:127.0.0.1:4000` until TLS is in place (DECISIONS.md D-10).
Cipher, MAC and key-exchange lists are governed by the system crypto policy
(`update-crypto-policies --show` should print `DEFAULT` or `FUTURE`); do not hand-edit them.

## 2.3 Updates

```bash
sudo dnf -y upgrade && sudo reboot            # if a kernel or glibc update was applied
sudo dnf -y install dnf-automatic
sudo sed -i -e 's/^upgrade_type = .*/upgrade_type = security/' -e 's/^apply_updates = .*/apply_updates = yes/' /etc/dnf/automatic.conf
sudo systemctl enable --now dnf-automatic.timer
grep -E '^(upgrade_type|apply_updates)' /etc/dnf/automatic.conf
```

Podman is delivered through the same channel (the rolling `container-tools` stream) and
receives security fixes there; because Podman has no daemon, a package update never
restarts the running containers. Container **images** are updated only deliberately
(docs/06-operations.md §6.3).

## 2.4 Time, logging, audit

- Time: `timedatectl` shows `System clock synchronized: yes` and `chronyd` is active.
- Journal: RHEL keeps a persistent journal in `/var/log/journal`; confirm with
  `journalctl --disk-usage`. Container logs go there too (`LogDriver=journald`), so set a
  cap if the disk is shared: `SystemMaxUse=2G` in `/etc/systemd/journald.conf.d/size.conf`.
- Audit rules for the files that decide who can log in, who is root and what the gateway runs:

```bash
sudo install -m 640 -o root -g root /opt/llm-gateway/repo/deploy/host/llm-gateway.rules /etc/audit/rules.d/llm-gateway.rules
sudo augenrules --load && sudo auditctl -l | grep -c -E 'sshd|sudo|subid|containers|firewall|gateway'
```

## 2.5 SELinux

Stays **enforcing** (`getenforce`). container-selinux confines every container to
`container_t`; the units label their bind mounts with `:Z` so nothing needs a boolean or
a custom module. If something is denied, read the denial rather than lowering the mode:

```bash
sudo ausearch -m AVC -ts recent
```

## 2.6 Kernel parameters

```bash
sudo install -m 644 -o root -g root /opt/llm-gateway/repo/deploy/host/90-hardening.conf /etc/sysctl.d/90-hardening.conf
sudo sysctl --system | grep -E 'rp_filter|accept_redirects|kptr_restrict|ptrace_scope'
sysctl user.max_user_namespaces net.ipv4.ip_unprivileged_port_start   # must be > 0 and 1024
```

`ip_forward` is left at the RHEL default: rootless Podman networks live in the service
account's own network namespace and do not route through the host. Port 4000 is above
the unprivileged-port boundary, so it needs no change either.

## 2.7 Inbound: firewalld

firewalld stays enabled. A port published by a rootless container is an ordinary
listening socket owned by `llmgw`, so firewalld's rules apply to it exactly as to any
other service (unlike Docker, which inserts its own chains ahead of the host's rules).

```bash
sudo firewall-cmd --get-default-zone            # public on a stock install
sudo firewall-cmd --permanent --zone=public --remove-service=cockpit
sudo firewall-cmd --permanent --zone=public --remove-service=dhcpv6-client
# SSH only from the admin network; replace the CIDR from the assessment.
sudo firewall-cmd --permanent --zone=public --remove-service=ssh
sudo firewall-cmd --permanent --zone=public --add-rich-rule='rule family="ipv4" source address="<admin-cidr>" service name="ssh" accept'
sudo firewall-cmd --reload && sudo firewall-cmd --list-all
```

Port 4000 is not opened in this phase: LiteLLM listens on `127.0.0.1` until validation
is complete (docs/05 §5.10 opens it for the client subnet).

## 2.8 Outbound: egress policy for the service account

Rootless Podman sends all container traffic through `pasta`, a process owned by `llmgw`,
so the host can attribute every outbound packet of the stack to that uid. The ruleset
in `deploy/host/llmgw-egress.nft` allows `llmgw` only established traffic, loopback, DNS
to the host resolvers and TCP 443; everything else from that uid is logged and dropped.
It is a separate nftables table that coexists with firewalld (which manages only its own
table). FQDN-level allow-listing of the provider APIs remains the network firewall's
job, as in the architecture.

```bash
sudo dnf -y install nftables
sudo install -m 644 -o root -g root /opt/llm-gateway/repo/deploy/host/llmgw-egress.nft /etc/nftables/llmgw-egress.nft
sudoedit /etc/nftables/llmgw-egress.nft         # fill the resolvers4 set from /etc/resolv.conf
sudo nft -c -f /etc/nftables/llmgw-egress.nft   # syntax check, applies nothing
echo 'include "/etc/nftables/llmgw-egress.nft"' | sudo tee -a /etc/sysconfig/nftables.conf
sudo systemctl enable --now nftables
sudo nft list table inet llmgw_egress
```

Apply this **after** phase 3 has created the `llmgw` user (nft resolves the name at load
time). Test in docs/04 §4.5: HTTPS from LiteLLM works, anything else from a container
appears in `journalctl -k | grep llmgw-egress-drop`.

## 2.9 Deployment directory

Created in phase 3 together with the service account (docs/03 §3.5): `/opt/llm-gateway`
owned `root:llmgw` mode `0750`, with `repo/`, `env/` and `data/` owned by `llmgw`.

## 2.10 Verification

- `sudo sshd -T` shows the intended values; a fresh SSH login works.
- `sudo firewall-cmd --list-all` shows only the SSH rich rule (no services) on `public`.
- `sudo nft list table inet llmgw_egress` shows the two chains (after phase 3).
- `sudo sysctl -a 2>/dev/null | grep -E 'rp_filter|accept_redirects|kptr_restrict'` matches the file.
- `sudo auditctl -l` lists the rules; `systemctl is-active auditd chronyd` both `active`.
- `getenforce` prints `Enforcing`.
- Re-run `scripts/assess.sh` and diff against the phase 1 report.

Optional independent check: `lynis audit system` (EPEL package `lynis`) gives a scored
baseline to compare before and after.
