# Phase 2: Host hardening

Applied only after the phase 1 report is reviewed. Each item is marked in the review
as **required**, **already in place**, or **not applicable**. Apply items one at a time
and verify each before the next; keep a second SSH session open while changing SSH or
firewall rules.

Commands are given for Debian/Ubuntu (apt) with RHEL-family (dnf) notes where they differ.

## 2.1 Accounts

- One named admin account with `sudo`; work from it, never from `root` directly.
- `sudo` entries limited to that account/group; no `NOPASSWD` unless required for
  automation and then scoped to specific commands.
- Remove or lock accounts the report shows as unused: `sudo usermod -L -e 1 <user>`.
- No account with an empty password (report section 3).
- Do **not** add users to the `docker` group: membership is root-equivalent. Operate the
  stack with `sudo docker compose ...` from the admin account.

## 2.2 SSH

Write a drop-in rather than editing the main file, then test before reloading:

```bash
sudo tee /etc/ssh/sshd_config.d/10-hardening.conf >/dev/null <<'CONF'
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
PermitEmptyPasswords no
AllowUsers <admin>
MaxAuthTries 3
LoginGraceTime 30
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
ClientAliveInterval 300
ClientAliveCountMax 2
CONF
sudo sshd -t && sudo systemctl reload ssh   # 'sshd' on RHEL-family
```

Confirm from a **new** session that key login still works before closing the old one.
Confirm the effective values: `sudo sshd -T | grep -Ei '^(permitrootlogin|passwordauthentication|allowusers)'`.

## 2.3 Updates

```bash
sudo apt-get update && sudo apt-get -y full-upgrade && sudo reboot   # if kernel updated
sudo apt-get install -y unattended-upgrades
sudo dpkg-reconfigure -plow unattended-upgrades       # security origin only is the default
```

RHEL-family: `sudo dnf -y upgrade`, then `dnf-automatic` with `upgrade_type = security`
and `apply_updates = yes`, `systemctl enable --now dnf-automatic.timer`.

Container images are updated separately (docs/06-operations.md); host auto-updates must
not touch Docker packages unexpectedly: pin them with `apt-mark hold docker-ce docker-ce-cli containerd.io docker-compose-plugin`
after phase 3 and update them deliberately.

## 2.4 Time, logging, audit

- Time sync active (`timedatectl` shows `System clock synchronized: yes`); install
  `chrony` if not.
- Persistent journal: `sudo mkdir -p /var/log/journal && sudo systemctl restart systemd-journald`
  (or `Storage=persistent` in `/etc/systemd/journald.conf`).
- `auditd` installed and running. Minimum rules worth having for this host, in
  `/etc/audit/rules.d/gateway.rules`:

```
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/sudoers -p wa -k sudo
-w /etc/sudoers.d/ -p wa -k sudo
-w /etc/docker/ -p wa -k docker
-w /opt/llm-gateway/ -p wa -k gateway
-w /var/run/docker.sock -p rwxa -k docker-sock
```

`sudo augenrules --load && sudo auditctl -l`.

## 2.5 Kernel / sysctl baseline

`/etc/sysctl.d/90-hardening.conf`:

```
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.all.log_martians = 1
net.ipv6.conf.all.accept_redirects = 0
net.ipv6.conf.all.accept_ra = 0
kernel.kptr_restrict = 2
kernel.dmesg_restrict = 1
kernel.yama.ptrace_scope = 1
kernel.randomize_va_space = 2
fs.protected_hardlinks = 1
fs.protected_symlinks = 1
fs.protected_fifos = 2
fs.protected_regular = 2
fs.suid_dumpable = 0
```

`sudo sysctl --system`. Do **not** set `net.ipv4.ip_forward = 0`: Docker needs
forwarding for published ports and container networking (it enables it itself).

## 2.6 Host firewall and Docker

Docker inserts its own rules ahead of the host's `INPUT` chain: a published container
port is reachable regardless of `ufw`/`firewalld` `INPUT` rules. Two controls make this
safe here:

1. **Bind narrowly.** The stack publishes LiteLLM only on `LITELLM_BIND_ADDR`
   (`127.0.0.1` for validation, then the internal LAN IP). PostgreSQL and Presidio are
   never published.
2. **Filter in `DOCKER-USER`.** Docker guarantees this chain is evaluated first for
   traffic to containers and never overwrites it. Restrict who may reach port 4000:

```bash
# Allow the client subnet(s) to reach LiteLLM, drop everything else destined to containers
# that arrives from outside the host. Adjust interface name and CIDRs from the report.
sudo iptables -I DOCKER-USER -i <ext-iface> -p tcp --dport 4000 -s <client-cidr> -j RETURN
sudo iptables -I DOCKER-USER -i <ext-iface> -m conntrack --ctstate ESTABLISHED,RELATED -j RETURN
sudo iptables -A DOCKER-USER -i <ext-iface> -j DROP
```

Persist with `iptables-persistent` (Debian/Ubuntu) or in firewalld's direct rules.
These rules can only be written **after** Docker is installed (phase 3) because Docker
creates the chain; until then a host firewall with default-deny inbound and an allow for
SSH from the admin network is the baseline:

```bash
sudo apt-get install -y nftables
sudo tee /etc/nftables.conf >/dev/null <<'NFT'
#!/usr/sbin/nft -f
flush ruleset
table inet filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iif lo accept
    ct state established,related accept
    ip protocol icmp accept
    ip6 nexthdr icmpv6 accept
    tcp dport 22 ip saddr <admin-cidr> accept
  }
  chain forward { type filter hook forward priority 0; policy accept; }
  chain output  { type filter hook output  priority 0; policy accept; }
}
NFT
sudo nft -c -f /etc/nftables.conf && sudo systemctl enable --now nftables
```

Egress restriction to provider APIs only belongs on the network firewall (as in the
architecture diagram); host-level egress filtering by FQDN is brittle and is not attempted.

## 2.7 Docker daemon defaults (applied in phase 3, listed here for review)

`/etc/docker/daemon.json`:

```json
{
  "log-driver": "json-file",
  "log-opts": { "max-size": "10m", "max-file": "5" },
  "live-restore": true,
  "no-new-privileges": true,
  "userland-proxy": false
}
```

`no-new-privileges` at daemon level backs the per-service setting in the compose file.
`userland-proxy: false` publishes ports with iptables DNAT only (no `docker-proxy`
process per port).

## 2.8 Deployment directory

```bash
sudo mkdir -p /opt/llm-gateway && sudo chown root:root /opt/llm-gateway && sudo chmod 750 /opt/llm-gateway
```

Secrets files inside it are `root:root 600`. Only root (via sudo) reads them; the Docker
daemon (root) passes them to the containers.

## 2.9 Verification

- `sudo sshd -T` shows the intended values; a fresh SSH login works.
- `sudo nft list ruleset` (or `iptables -S`) shows default-deny inbound with SSH allowed.
- `sudo sysctl -a 2>/dev/null | grep -E 'rp_filter|accept_redirects|kptr_restrict'` matches.
- `sudo auditctl -l` lists the rules; `systemctl is-active auditd chrony` both `active`.
- Re-run `scripts/assess.sh` and diff against the phase 1 report.

Optional independent check: `lynis audit system` (package `lynis`) gives a scored
baseline to compare before/after.
