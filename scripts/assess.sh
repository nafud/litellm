#!/usr/bin/env bash
# Read-only server assessment for the LiteLLM + Presidio + PostgreSQL deployment.
#
# Makes NO changes to the system. Every command is an inspection; failures are
# tolerated and recorded so the report is complete even on minimal images.
#
# Usage (run as root, or with sudo, for the full picture):
#   sudo bash scripts/assess.sh                # writes reports/assessment-<host>-<date>.txt
#   sudo bash scripts/assess.sh /tmp/out.txt   # custom output path
#
# The report contains host details (users, ports, sudoers). reports/ is git-ignored.

set -u
umask 077

OUT="${1:-}"
HOST_SHORT="$(hostname -s 2>/dev/null || hostname)"
if [ -z "$OUT" ]; then
  SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$SCRIPT_DIR/../reports"
  OUT="$SCRIPT_DIR/../reports/assessment-${HOST_SHORT}-$(date +%Y%m%d-%H%M%S).txt"
fi

exec > >(tee "$OUT") 2>&1

section() { printf '\n\n===== %s =====\n' "$1"; }
have()    { command -v "$1" >/dev/null 2>&1; }
# run "description" cmd args...  -> prints the command, its output, and its exit code
run() {
  local desc="$1"; shift
  printf -- '--- %s\n$ %s\n' "$desc" "$*"
  "$@" 2>&1
  printf '[exit %s]\n' "$?"
}
# runsh "description" 'shell pipeline'
runsh() {
  local desc="$1" cmd="$2"
  printf -- '--- %s\n$ %s\n' "$desc" "$cmd"
  bash -c "$cmd" 2>&1
  printf '[exit %s]\n' "$?"
}

IS_ROOT=0; [ "$(id -u)" = "0" ] && IS_ROOT=1

section "0. Assessment metadata"
echo "generated : $(date -u +%Y-%m-%dT%H:%M:%SZ) (UTC)"
echo "run as    : $(id)"
echo "root      : $IS_ROOT (0 = some sections will be incomplete)"
echo "output    : $OUT"

section "1. Identity, OS, kernel, virtualisation"
run "hostname" hostname -f
run "os-release" cat /etc/os-release
run "kernel" uname -a
run "architecture" uname -m
have systemd-detect-virt && run "virtualisation" systemd-detect-virt
have hostnamectl && run "hostnamectl" hostnamectl
run "uptime" uptime
have timedatectl && run "time sync" timedatectl
run "locale/timezone" cat /etc/timezone

section "2. Hardware and capacity"
run "cpu count" nproc
runsh "cpu model" "grep -m1 'model name' /proc/cpuinfo"
run "memory" free -h
run "block devices" lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINTS
run "filesystems" df -hT -x tmpfs -x devtmpfs -x overlay
run "swap" swapon --show
run "mounts with options" findmnt -t ext4,xfs,btrfs -o TARGET,SOURCE,FSTYPE,OPTIONS

section "3. Accounts and privilege"
runsh "uid 0 accounts" "awk -F: '\$3==0 {print \$1}' /etc/passwd"
runsh "human accounts (uid>=1000)" "awk -F: '\$3>=1000 && \$3<65534 {print \$1\":\"\$3\":\"\$7}' /etc/passwd"
runsh "accounts with a login shell" "grep -vE '(nologin|false|sync|halt|shutdown)$' /etc/passwd"
if [ $IS_ROOT = 1 ]; then
  runsh "accounts with EMPTY password (must be none)" "awk -F: '(\$2==\"\") {print \$1}' /etc/shadow"
  runsh "accounts with a password set" "awk -F: '(\$2!~/^[!*]/ && \$2!=\"\") {print \$1}' /etc/shadow"
  run "sudoers" cat /etc/sudoers
  runsh "sudoers.d" "for f in /etc/sudoers.d/*; do [ -f \"\$f\" ] && { echo \"## \$f\"; cat \"\$f\"; }; done"
fi
runsh "sudo/wheel/adm/docker group members" "getent group sudo wheel adm docker"
runsh "authorized_keys files" "find / -xdev -name authorized_keys -not -path '*/proc/*' 2>/dev/null | while read -r f; do echo \"## \$f (\$(wc -l < \"\$f\") keys)\"; done"
run "last logins" last -n 20 -a
run "failed logins (lastb)" lastb -n 20 -a
runsh "password policy (login.defs)" "grep -E '^(PASS_MAX_DAYS|PASS_MIN_DAYS|PASS_WARN_AGE|UMASK|ENCRYPT_METHOD)' /etc/login.defs"

section "4. SSH"
if have sshd && [ $IS_ROOT = 1 ]; then
  runsh "effective sshd config (selected)" "sshd -T 2>/dev/null | grep -Ei '^(port|permitrootlogin|passwordauthentication|pubkeyauthentication|kbdinteractiveauthentication|challengeresponseauthentication|allowusers|allowgroups|maxauthtries|logingracetime|x11forwarding|clientaliveinterval|clientalivecountmax|permitemptypasswords|usepam|listenaddress|ciphers|macs|kexalgorithms|hostkeyalgorithms) '"
else
  runsh "sshd_config (non-comment lines)" "grep -vE '^\s*(#|$)' /etc/ssh/sshd_config; ls /etc/ssh/sshd_config.d/ 2>/dev/null && cat /etc/ssh/sshd_config.d/*.conf 2>/dev/null"
fi
runsh "ssh host key types" "ls -l /etc/ssh/ssh_host_*_key.pub 2>/dev/null"

section "5. Network"
if have ip; then
  run "interfaces" ip -br addr
  run "routes" ip route
  run "ipv6 routes" ip -6 route
else
  echo "ip (iproute2) not installed"; have ifconfig && run "interfaces (ifconfig)" ifconfig -a
fi
run "resolv.conf" cat /etc/resolv.conf
have resolvectl && run "resolvectl status" resolvectl status
if have ss; then
  run "listening sockets" ss -tulpn
  run "established connections" ss -tnp state established
else
  echo "ss (iproute2) not installed"; have netstat && run "listening sockets (netstat)" netstat -tulpn
fi
runsh "proxy environment" "env | grep -i _proxy; cat /etc/environment 2>/dev/null | grep -i proxy; ls /etc/apt/apt.conf.d/ 2>/dev/null | grep -i proxy"

section "6. Firewall (host)"
have ufw && run "ufw status" ufw status verbose
have firewall-cmd && run "firewalld state" firewall-cmd --state && run "firewalld active zones" firewall-cmd --list-all
have nft && run "nftables ruleset" nft list ruleset
have iptables && run "iptables filter -S" iptables -S
have iptables && run "iptables nat -S" iptables -t nat -S
have ip6tables && run "ip6tables filter -S" ip6tables -S

section "7. Services, timers, cron"
have systemctl && run "running services" systemctl list-units --type=service --state=running --no-pager
have systemctl && run "enabled services" systemctl list-unit-files --type=service --state=enabled --no-pager
have systemctl && run "timers" systemctl list-timers --all --no-pager
runsh "system crontabs" "cat /etc/crontab 2>/dev/null; ls -la /etc/cron.d 2>/dev/null"
if [ $IS_ROOT = 1 ]; then
  runsh "user crontabs" "for u in \$(cut -f1 -d: /etc/passwd); do crontab -l -u \"\$u\" 2>/dev/null | sed \"s/^/[\$u] /\"; done"
fi

section "8. Packages and updates"
if have apt-get; then
  run "apt sources" bash -c "cat /etc/apt/sources.list 2>/dev/null; cat /etc/apt/sources.list.d/* 2>/dev/null"
  runsh "upgradable packages (from cached lists; run 'apt-get update' first for accuracy)" "apt list --upgradable 2>/dev/null | tail -n +2"
  runsh "unattended-upgrades" "dpkg -l unattended-upgrades 2>/dev/null | tail -1; cat /etc/apt/apt.conf.d/20auto-upgrades 2>/dev/null; systemctl is-active unattended-upgrades 2>/dev/null"
  runsh "docker packages (distro vs docker.com)" "dpkg -l | grep -Ei 'docker|containerd|podman' "
elif have dnf; then
  runsh "pending updates" "dnf check-update 2>/dev/null | tail -n +3"
  runsh "dnf-automatic" "rpm -q dnf-automatic; systemctl is-active dnf-automatic.timer 2>/dev/null; cat /etc/dnf/automatic.conf 2>/dev/null"
  runsh "docker packages" "rpm -qa | grep -Ei 'docker|containerd|podman'"
elif have zypper; then
  run "pending patches" zypper --non-interactive list-patches
fi

section "9. Security controls"
have getenforce && run "SELinux" getenforce
have sestatus && run "sestatus" sestatus
have aa-status && run "AppArmor" aa-status --json
runsh "AppArmor (fallback)" "cat /sys/module/apparmor/parameters/enabled 2>/dev/null"
have auditctl && run "auditd rules" auditctl -l
have systemctl && runsh "auditd / fail2ban / chrony / timesyncd state" "for s in auditd fail2ban chronyd chrony systemd-timesyncd rsyslog systemd-journald; do printf '%-22s %s\n' \$s \$(systemctl is-active \$s 2>/dev/null); done"
runsh "journald persistence" "grep -E '^\s*Storage' /etc/systemd/journald.conf 2>/dev/null; ls -d /var/log/journal 2>/dev/null"
runsh "sysctl (security-relevant)" "sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.conf.all.accept_redirects net.ipv4.conf.all.send_redirects net.ipv4.conf.all.accept_source_route net.ipv4.conf.all.log_martians net.ipv6.conf.all.accept_redirects kernel.kptr_restrict kernel.dmesg_restrict kernel.yama.ptrace_scope kernel.randomize_va_space fs.protected_hardlinks fs.protected_symlinks fs.protected_fifos fs.protected_regular kernel.unprivileged_userns_clone 2>&1"
runsh "kernel lockdown" "cat /sys/kernel/security/lockdown 2>/dev/null"
runsh "core dumps" "cat /proc/sys/kernel/core_pattern; grep -E '^\s*Storage' /etc/systemd/coredump.conf 2>/dev/null"
runsh "world-writable dirs without sticky bit (should be none)" "find / -xdev -type d -perm -0002 ! -perm -1000 2>/dev/null | head -50"
runsh "SUID/SGID binaries" "find / -xdev \( -perm -4000 -o -perm -2000 \) -type f 2>/dev/null"

section "10. Container runtime (existing)"
if have podman; then
  run "podman version" podman version
  run "podman info" podman info
  run "containers (all, root)" podman ps -a
  run "images (root)" podman images
  run "networks (root)" podman network ls
  runsh "subordinate id ranges" "cat /etc/subuid /etc/subgid"
  runsh "lingering users" "ls -1 /var/lib/systemd/linger 2>/dev/null"
  runsh "rootful quadlets" "ls -lR /etc/containers/systemd 2>/dev/null"
  runsh "registries.conf" "grep -v '^\s*#' /etc/containers/registries.conf | grep -v '^\s*$'"
  runsh "policy.json" "cat /etc/containers/policy.json"
else
  echo "podman: not installed"
fi
if have docker; then
  run "docker version" docker version
  run "containers (all)" docker ps -a
  runsh "docker socket perms" "ls -l /var/run/docker.sock"
else
  echo "docker: not installed"
fi
have cosign && run "cosign version" cosign version
runsh "container packages" "rpm -q podman netavark aardvark-dns container-selinux passt crun conmon skopeo shadow-utils-subid 2>&1"

section "11. Egress reachability (read-only GET/HEAD, 8s timeout)"
# 000 = no connection (blocked or DNS failure). Any HTTP code means the path is open.
for u in \
  https://ghcr.io/v2/ \
  https://registry-1.docker.io/v2/ \
  https://cdn.redhat.com/ \
  https://github.com/ \
  https://api.anthropic.com/ \
  https://api.openai.com/ \
  https://generativelanguage.googleapis.com/ \
  https://deb.debian.org/ \
  https://archive.ubuntu.com/ ; do
  code=$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "$u" 2>/dev/null); code=${code:-000}
  printf '%-48s HTTP %s\n' "$u" "$code"
done
runsh "DNS resolution" "for h in ghcr.io api.anthropic.com registry-1.docker.io; do getent hosts \$h || echo \"\$h: NO RESOLUTION\"; done"

section "12. Existing PostgreSQL / Python / ports 4000,5432,3000 in use?"
runsh "postgres processes" "pgrep -a postgres"
have ss && runsh "ports 4000 5432 3000 5001 5002" "ss -tlnp | grep -E ':(4000|5432|3000|5001|5002)\s'"
have python3 && run "python3" python3 --version

section "13. Logs: recent auth failures and kernel warnings"
runsh "auth failures (journal, 48h)" "journalctl -u ssh -u sshd --since '48 hours ago' --no-pager 2>/dev/null | grep -iE 'fail|invalid' | tail -30"
runsh "dmesg errors" "dmesg --level=err,crit,alert,emerg 2>/dev/null | tail -30"

section "END"
echo "Report written to: $OUT"
echo "Review before sharing: it lists users, keys locations and open ports."
