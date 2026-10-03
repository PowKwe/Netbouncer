# Tailscale Kernel-Mode Exit Node / Subnet Router on Rooted Android

Turns a rooted Android phone into a real **kernel-mode** Tailscale subnet router and exit node: a genuine `tailscale0` TUN interface with in-kernel routing and NAT, not Tailscale's `userspace-networking` fallback.

Tested on a Samsung Galaxy S10+ (Exynos, codename `beyond2lte`), running **LineageOS**, rooted with Magisk.

**Tested versions** — these are moving targets; if something in this doc doesn't match your result, check this list first.

| Component | Version | 
| --------- | ------- | 
| `external_tailscale` (patched fork) | 1.92.4-31-t1f91011a1 |
| PRoot container kernel | Linux 6.17.0-PRoot-Distro, aarch64 |
| ROM | LineageOS 23.2-20260905-nightly-beyond2lte |
| Magisk | v30.7 |
| Pi-hole core / web / FTL | v6.4.3 / v6.6 / v6.7.1 |
| Ubuntu release (inside PRoot) | 26.04.1 LTS "Resolute Raccoon" |
| Termux / Termux:Boot | 1.46.0+really1.45.0-1 aarch64 |

**What's in this repo**

- A fix for the two ways Android breaks stock Tailscale's routing (see [Why this is harder than on Linux](#why-this-is-harder-than-on-linux))
- A boot script (`master-boot.sh`) that makes the setup survive reboots
- Two optional add-ons: [SSH access](#optional-ssh-access) and [Pi-hole ad-blocking](#optional-pi-hole-dns-and-ad-blocking)

## Contents

1. [Why this is harder than on Linux](#why-this-is-harder-than-on-linux)
2. [The fix](#the-fix)
3. [Requirements](#requirements)
4. [Installation](#installation)
5. [The boot script](#the-boot-script-master-bootsh)
6. [Verification](#verification)
7. [Optional: SSH access](#optional-ssh-access)
8. [Optional: Pi-hole DNS and ad-blocking](#optional-pi-hole-dns-and-ad-blocking)
9. [Troubleshooting](#troubleshooting)
10. [Credits](#credits) · [Disclaimer](#disclaimer)

---

## Why this is harder than on Linux

On a normal Linux box, Tailscale inserts a few `ip rule` entries and everything works. Android breaks that in two independent ways:

1. **fwmark collisions.** Android's `netd` reserves the lower bits of the 32-bit socket fwmark for its own per-network and per-UID bookkeeping. Stock Tailscale's default fwmark bits overlap that range, so each side can corrupt the other's packet marks.
2. **Policy-routing (RPDB) interference.** Android keeps dozens of `ip rule` entries per network/UID range, generally at priority 10000 or higher, for per-app VPNs, metered-connection logic and multi-network handling. Stock Tailscale assumes a much simpler setup. Its rules are either shadowed by Android's, or they bypass Android's rules and disturb routing for unrelated traffic.

The result: stock `tailscaled` either silently falls back to non-functional routing or interferes with the phone's normal networking.

## The fix

The setup uses a patched, Android-aware fork of Tailscale, [`android-kxxt/external_tailscale`](https://github.com/android-kxxt/external_tailscale), which:

- moves Tailscale's fwmark bits into the range Android's `netd` leaves unclaimed;
- replaces Tailscale's multi-rule `ip rule` insertion with a single rule at a priority that doesn't shadow Android's;
- patches `go-iptables` to tolerate Android's non-standard iptables error strings.

**One extra fix is needed on-device** and is not part of the upstream patch: explicit `ip rule` entries that make the kernel resolve a next hop for packets arriving on `tailscale0` (the first one points at the `main` table; the second at Android's per-interface routing table for the uplink; see [step 4 of the boot script](#the-boot-script-master-bootsh)). Without them, packets reach the tun interface and are accepted by the `FORWARD` chain, but no route is found, so nothing is forwarded even though every iptables rule looks correct. This is what takes the router from "exit node offered, client connected, zero traffic" to working.

## Requirements

- Rooted Android device with Magisk
- Root shell access (Termux + `su`, or ADB)
- `tailscale` and `tailscaled` binaries from the patched fork, built for your device's ABI (arm64 on most modern devices)
- A Tailscale account
- **For the optional add-ons only:** [Termux](https://github.com/termux/termux-app) and [Termux:Boot](https://github.com/termux/termux-boot). Install both from the **same source** (F-Droid or Play Store); builds from different sources are not signature-compatible and won't talk to each other.

## Installation

### 1. Get the patched binaries

Download a prebuilt release for your ABI if one is available, or build from source:

```sh
git clone https://github.com/android-kxxt/external_tailscale.git
cd external_tailscale
GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -o tailscaled ./cmd/tailscaled
GOOS=android GOARCH=arm64 CGO_ENABLED=0 go build -o tailscale ./cmd/tailscale
```

Check that the fork isn't badly out of date with current Tailscale releases; a build that is too old may fail to authenticate against the current control-plane protocol.

### 2. Put the binaries on the device

Copy them to somewhere readable first (for example `adb push tailscale tailscaled /data/local/tmp/`), then, from a root shell:

```sh
mkdir -p /data/adb/tailscale
cp /data/local/tmp/tailscale /data/local/tmp/tailscaled /data/adb/tailscale/
chmod 755 /data/adb/tailscale/tailscale /data/adb/tailscale/tailscaled
chown root:root /data/adb/tailscale/tailscale /data/adb/tailscale/tailscaled
```

### 3. Install the boot script

Save the script from [The boot script](#the-boot-script-master-bootsh) as `/data/adb/service.d/master-boot.sh`, then (as root):

```sh
chmod 755 /data/adb/service.d/master-boot.sh
```

Magisk runs `service.d` scripts late in boot. The script itself waits for `sys.boot_completed` before doing anything.

### 4. Reboot and check the interface

```sh
ip link show tailscale0
```

### 5. Authenticate and configure the router (one time, root shell)

```sh
/data/adb/tailscale/tailscale --socket=/data/adb/tailscale/tailscaled.sock up \
  --accept-dns=false \
  --advertise-routes=192.168.X.0/24 \
  --advertise-exit-node
```

Replace `192.168.X.0/24` with your LAN subnet. Open the printed login URL and approve the device. The settings are stored in the daemon's state file, so you don't need to run `up` again after reboots.

### 6. Approve the route and exit node in the admin console

Open the [Tailscale admin console](https://login.tailscale.com/admin/machines) and approve both. Advertising is not the same as being active: clients can't use the subnet route or exit node until you approve them.

Then run through [Verification](#verification). SSH and Pi-hole are optional and covered further down.

---

## The boot script (`master-boot.sh`)

Install at `/data/adb/service.d/master-boot.sh`. It enables forwarding, adds the routing and NAT rules, optionally redirects DNS to Pi-hole, and starts `tailscaled`. It deliberately does **not** start `sshd` ([why](#why-sshd-is-not-in-the-magisk-script)).

```sh
#!/system/bin/sh
# --- Settings ---------------------------------------------------------------
UPLINK=wlan0          # Interface that carries your internet/LAN traffic.
                      # Find it with: ip route get 8.8.8.8 (run this from a
                      # host root shell — see the note below the script)
PIHOLE_REDIRECT=0     # Set to 1 only after Pi-hole is installed and running
                      # (see the Pi-hole section). Leave at 0 otherwise, or
                      # DNS will break for every client using this node.
# ----------------------------------------------------------------------------

until [ "$(getprop sys.boot_completed)" = "1" ]; do sleep 1; done
sleep 10

# 1. Enable IP forwarding (IPv4 and IPv6)
echo 1 > /proc/sys/net/ipv4/ip_forward
echo 1 > /proc/sys/net/ipv6/conf/all/forwarding

# 2. Disable reverse-path filtering so Android doesn't drop forwarded packets
echo 0 > /proc/sys/net/ipv4/conf/all/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/default/rp_filter
echo 0 > /proc/sys/net/ipv4/conf/$UPLINK/rp_filter

# 3. Find Android's per-network routing table for the uplink (1000 + ifindex).
#    This table is created and populated by Android's own netd, independently
#    of this script — the script only reads from it, never writes to it.
IDX=$(cat /sys/class/net/$UPLINK/ifindex 2>/dev/null)
TABLE=$((1000 + IDX))

# 4. Policy routing for traffic arriving from Tailscale. The deletes make the
#    script safe to re-run without piling up duplicate rules.
ip rule del iif tailscale0 lookup main pref 4999 2>/dev/null
ip rule add iif tailscale0 lookup main pref 4999
if [ -n "$IDX" ]; then
    ip rule del iif tailscale0 lookup $TABLE pref 5000 2>/dev/null
    ip rule add iif tailscale0 lookup $TABLE pref 5000
fi

# 5. NAT and forwarding (each rule is only added if it isn't already present)
iptables -t nat -C POSTROUTING -o $UPLINK -j MASQUERADE 2>/dev/null || \
    iptables -t nat -I POSTROUTING -o $UPLINK -j MASQUERADE
iptables -C FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -i tailscale0 -j ACCEPT
iptables -C FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || \
    iptables -I FORWARD -o tailscale0 -j ACCEPT

# 6. Optional: redirect DNS (port 53) to Pi-hole listening on port 5353
if [ "$PIHOLE_REDIRECT" = "1" ]; then
    for proto in udp tcp; do
        iptables -t nat -C PREROUTING -p $proto --dport 53 -j REDIRECT --to-ports 5353 2>/dev/null || \
            iptables -t nat -A PREROUTING -p $proto --dport 53 -j REDIRECT --to-ports 5353
    done
fi

# 7. Start Tailscale in kernel mode
env XDG_CACHE_HOME=/data/adb/tailscale \
/data/adb/tailscale/tailscaled \
    --state=/data/adb/tailscale/tailscaled.state \
    --socket=/data/adb/tailscale/tailscaled.sock &

# 8. Once tailscale0 exists, disable its rp_filter too
sleep 5
echo 0 > /proc/sys/net/ipv4/conf/tailscale0/rp_filter 2>/dev/null
```

Notes on what the script does and doesn't cover:

- **Why two `ip rule` entries, and which one actually matters.** The first (priority 4999) resolves routes from the `main` table. The second (priority 5000) falls back to Android's own per-interface table for the uplink (`1000 + ifindex`). Testing found that on this device, `main` has no default route at all after a cold boot — only the second rule, against Android's `netd`-managed table, actually resolves anything. Both rules are kept regardless: the `main`-table rule costs nothing to keep and may be the one that matters on a different device or Android version, while the per-interface table is the one shown to work here. Both only match traffic arriving on `tailscale0`, and both sit at lower numbers than Android's own rules (10000+), so they are checked first.
- **The uplink table is computed once, at boot, from a table Android itself maintains.** The script does not create or populate table `1000 + ifindex` — it only reads from it. The Wi-Fi interface must exist when the script runs, and the table must have been populated by `netd` by that point; if the ifindex lookup fails, the second rule is skipped.
- **Auto-detecting the uplink interface by name is unreliable, so it's set by hand.** `ip route get 8.8.8.8` reliably reports the correct outbound interface and next hop when run from a host Android root shell — it was used throughout testing to confirm gateways and interfaces. It is not reliable, however, inside a PRoot container (see [Part 1 of the Pi-hole section](#part-1-install-pi-hole-in-proot)): PRoot's syscall interception doesn't provide working netlink sockets, so commands like `ip route get` fail there with a generic error. Parsing `ip route show` output for `dev <iface>` in a portable way across BusyBox/toybox builds added fragility without enough payoff for a boot script, so a fixed `UPLINK` variable is used instead; confirm the right value once with `ip route get 8.8.8.8` from the host shell, then hardcode it.
- **Mobile data isn't covered.** NAT is applied to `$UPLINK` only. To route out over cellular you would need a matching `MASQUERADE` rule for that interface (typically `rmnet*`).
- **IPv6 is forwarded but not NATed.** The script enables IPv6 forwarding but only adds IPv4 (`iptables`) rules. Exit-node traffic is therefore effectively IPv4-only.

---

## Verification

Confirm the router is actually forwarding traffic, not merely configured to:

```sh
# Policy routing: your rules at 4999/5000 and Tailscale's rule should be
# evaluated before Android's netd rules (lower number = checked first)
ip rule

# Which table the 5000 rule actually points at, and whether it has a route
ip route show table $((1000 + $(cat /sys/class/net/wlan0/ifindex)))

# Tailscale's own routing table
ip route show table 52

# Daemon status and peer connectivity
/data/adb/tailscale/tailscale --socket=/data/adb/tailscale/tailscaled.sock status

# Forwarding and NAT counters: these must GROW while a client is using the node
iptables -L FORWARD -n -v
iptables -t nat -L POSTROUTING -n -v

# Tailscale's own chains (present only if the daemon created them)
iptables -L ts-input -n -v
iptables -L ts-forward -n -v
```

"Approved" in the admin console and "forwarding packets" are different things. Always confirm with nonzero, growing counters under real client traffic, not just green checkmarks.

---

## Optional: SSH access

Handy for administering the phone from your tailnet.

### Why sshd is not in the Magisk script

Starting `sshd` from a Magisk `service.d` script (for example with `su <termux-uid> -c ...`) switches the process to Termux's UID, but it does **not** get the group memberships or SELinux context of a normally launched Termux app:

|                 | Normal Termux launch                 | `su <uid>` from a Magisk script    |
| --------------- | ------------------------------------- | ----------------------------------- |
| Groups          | `...,3003(inet),9997(everybody),...`  | _(none; just the base UID group)_   |
| SELinux context | `u:r:untrusted_app_27:s0:...`         | `u:r:magisk:s0`                     |

The missing `inet` group (gid 3003) is what gates network socket creation for app processes. The symptom: over SSH into such an `sshd`, `pkg update` and `pkg install` fail with "all mirrors bad", yet the same commands work once you open Termux physically and start `sshd` there, because that process comes from Android's normal app-launch path.

**Fix:** start `sshd` through Termux:Boot instead.

### Setup

1. Install Termux:Boot (same source as Termux; see [Requirements](#requirements)) and **open the app once** so Android registers its boot receiver.
2. Set Termux:Boot's battery usage to **Unrestricted** in Android settings (Settings → Apps → Termux:Boot → Battery), or the boot broadcast may never arrive.
3. Set a password (`passwd`) or add your key to `~/.ssh/authorized_keys` in Termux. Termux's `sshd` listens on port **8022**, not 22.
4. In Termux, create the boot script:
   ```sh
   mkdir -p ~/.termux/boot
   cat > ~/.termux/boot/start-sshd.sh << 'EOF'
   #!/data/data/com.termux/files/usr/bin/sh
   termux-wake-lock    # keep the CPU from deep-sleeping while sshd runs
   sshd
   EOF
   chmod +x ~/.termux/boot/start-sshd.sh
   ```
5. Reboot, then test SSH **without** opening Termux on screen first. That is the real test that the daemon starts through the correct app context.

If Termux:Boot is unreliable on your build (it depends on the boot-completed broadcast reaching a background app), fall back to opening Termux manually once after each reboot.

---

## Optional: Pi-hole DNS and ad-blocking

Turns the phone into a network-wide ad-blocker. Pi-hole v6 runs inside an Ubuntu PRoot container (`proot-distro`), is reached through a Magisk iptables redirect, and is started at boot by Termux:Boot.

**Status:** tested end to end. Queries from a tailnet client appear in the Pi-hole query log, and after a reboot an `nmap` scan from the LAN shows port 53 (dnsmasq/Pi-hole), 8080 (dashboard) and 8022 (SSH) open.

**Do this after the core setup works.** Don't enable the DNS redirect in `master-boot.sh` until Pi-hole is up (Part 4).

### Architecture and ports

Android doesn't let non-root apps bind ports below 1024, and PRoot's "root" is only a fake one, so Pi-hole uses unprivileged ports:

| Service       | Port inside PRoot | How clients reach it                          |
| ------------- | ------------------ | ---------------------------------------------- |
| DNS           | 5353                | Magisk redirects incoming port 53 to 5353      |
| Web dashboard | 8080                | Directly, from the LAN or over Tailscale       |

The redirect uses the `nat PREROUTING` chain, so it applies to DNS traffic **arriving at** the phone (tailnet and LAN clients), not to the phone's own lookups. It matches any port-53 traffic, so forwarded queries to external resolvers (for example `8.8.8.8`) are redirected to Pi-hole too. If Pi-hole stops, those clients lose DNS.

### Part 1: Install Pi-hole in PRoot

**1. In Termux:** install PRoot and Ubuntu.

```sh
pkg install proot-distro
proot-distro install ubuntu
```

**2. Enter the container and install dependencies.** The package index is empty on first start, so run `apt update` first.

```sh
proot-distro login ubuntu
apt update && apt upgrade -y
apt install curl wget sudo nano dialog tzdata iproute2 -y
```

**3. Still inside Ubuntu:** pre-seed the installer. The interactive installer fails in PRoot (it can't query routes without `CAP_NET_ADMIN` — see the uplink-detection note under [The boot script](#the-boot-script-master-bootsh)), so write the answers file first.

```sh
mkdir -p /etc/pihole
cat > /etc/pihole/setupVars.conf << 'EOF'
PIHOLE_INTERFACE=wlan0
IPV4_ADDRESS=127.0.0.1/24
IPV6_ADDRESS=
PIHOLE_DNS_1=8.8.8.8
PIHOLE_DNS_2=1.1.1.1
INSTALL_WEB_SERVER=true
INSTALL_WEB_INTERFACE=true
LIGHTTPD_ENABLED=true
QUERY_LOGGING=true
DNSMASQ_LISTENING=all
EOF
```

**4. Run the unattended installer** (it reads the file from step 3):

```sh
curl -sSL https://install.pi-hole.net | bash /dev/stdin --unattended
```

It ends with `System has not been booted with systemd as init system`. That is expected: there is no `systemd` in PRoot, so the installer can't start the service. Everything is installed; you start FTL yourself.

**5. Move Pi-hole off the default ports** (inside Ubuntu):

```sh
pihole-FTL --config dns.port 5353
pihole-FTL --config webserver.port "8080,[::]:8080"
```

**6. Disable the built-in NTP server.** FTL v6 tries to serve time on port 123, which it isn't allowed to bind, so Pi-hole diagnosis shows red `Permission denied` errors. The phone already keeps its own time, so turn it off:

```sh
pihole-FTL --config ntp.ipv4.active false
pihole-FTL --config ntp.ipv6.active false
```

**7. Create the log directory and set the dashboard password.** PRoot doesn't recreate volatile folders such as `/var/run` or some log directories.

```sh
mkdir -p /var/log/pihole
chown pihole:pihole /var/log/pihole
pihole setpassword
```

**8. Start FTL and test the dashboard:**

```sh
pihole-FTL &
curl -I http://127.0.0.1:8080/admin/     # expect HTTP 200 or 302
```

`pihole-FTL` has no restart option. To restart after changing settings (step 6 included), run `killall pihole-FTL` and then `pihole-FTL &` again.

To test DNS itself before enabling the redirect, install `dnsutils` (not part of the tested package list) and query port 5353 directly:

```sh
apt install dnsutils -y
dig @127.0.0.1 -p 5353 example.com
```

### Part 2: Blocklists and first-run fixes

Pi-hole ships with StevenBlack's unified hosts list. A popular, deliberately conservative addition is [OISD](https://oisd.nl): in the dashboard go to **Adlists**, add `https://big.oisd.nl/`, then run `pihole -g` (or **Tools → Update Gravity**).

- **Paste the plain URL only.** If you copy a link from a chat or Markdown page you can end up with `[https://big.oisd.nl/](https://big.oisd.nl/)` in the Address field. Pi-hole reads it literally, can't download it, and the list shows a red error.
- **"Cannot open gravity database for writing"** when adding a list: the installer ran as root, so `/etc/pihole` can end up owned by the wrong user while FTL's web server runs as `pihole`. Inside Ubuntu run:
  ```sh
  chown -R pihole:pihole /etc/pihole
  killall pihole-FTL
  pihole-FTL &
  pihole -g
  ```
  Run it **inside the container**: in the Android root shell you get `chown: bad user 'pihole'`, because the `pihole` user exists only inside Ubuntu. In testing, `chmod -R 775/777 /etc/pihole` and inserting the list with `pihole-FTL sqlite3` were also tried before the list finally appeared after `pihole -g` and an FTL restart. It isn't established that the `chmod` or SQL steps were needed, so try the `chown` + restart first.
- **Some ads still get through.** Pi-hole only sees domain names. YouTube, Instagram and similar apps serve ads from the same domains as their content, and OISD intentionally leaves some trackers alone so apps don't break. For a domain you do want blocked, press **Deny** next to it in the Query Log.

### Part 3: Start Pi-hole at boot (Termux:Boot)

In Termux (a normal shell, **not** `su`), create the boot script. This assumes Termux:Boot is installed and has been opened once (see [SSH access](#optional-ssh-access) for the details).

```sh
cat > ~/.termux/boot/start-pihole.sh << 'EOF'
#!/data/data/com.termux/files/usr/bin/sh

# Restore the Termux environment that proot-distro needs
export PATH=/data/data/com.termux/files/usr/bin:/system/bin
export PREFIX=/data/data/com.termux/files/usr
export HOME=/data/data/com.termux/files/home
export LD_PRELOAD=/data/data/com.termux/files/usr/lib/libtermux-exec.so

# Give Android's network and Termux time to come up
sleep 15

# Remove stale lock files and sockets from unclean shutdowns
proot-distro login ubuntu -- rm -f /run/pihole/FTL.sock /run/pihole-FTL.pid /run/pihole-FTL.port /etc/pihole/pihole-FTL.db-journal 2>/dev/null

# Run FTL in the foreground (-f) to keep PRoot alive; background the proot command
nohup proot-distro login ubuntu -- pihole-FTL -f > /dev/null 2>&1 &
EOF
chmod 755 ~/.termux/boot/start-pihole.sh
```

**Required:** set Termux:Boot's battery usage to **Unrestricted** (Settings → Apps → Termux:Boot → Battery), otherwise Android may never deliver the boot broadcast.

**What each piece is for**, since all of it is needed:

| Piece | Why |
| ----- | --- |
| The four `export` lines | Termux:Boot runs scripts with an almost empty environment. `proot-distro` is itself a shell script that needs `PATH`/`PREFIX`/`HOME`, and `LD_PRELOAD` loads `libtermux-exec.so`, which rewrites `#!/bin/...` shebangs to Termux's paths. Without them the script fails silently. |
| `sleep 15` | An arbitrary settling delay. It is unrelated to the 10-second sleep in `master-boot.sh`; the two scripts run independently, in different contexts. |
| The `rm -f` line | In PRoot, `/run` is an ordinary folder on flash storage, not RAM-backed `tmpfs`, so it is not emptied on reboot. A leftover PID file makes FTL think it is already running. `--` ends `proot-distro`'s own options. |
| `pihole-FTL -f` | PRoot keeps the container alive only while the process it launched is alive. FTL normally daemonizes and exits its main process, which makes PRoot tear down the container, killing DNS and the dashboard. `-f` keeps FTL in the foreground. |
| `nohup ... &` | Detaches the whole proot command from the boot script so the script can finish. |
| `> /dev/null 2>&1` | Stops `nohup` from creating an ever-growing `nohup.out`. |

`sshd` starts fine from Termux:Boot without the `export` lines because it is a native Termux binary, whereas `proot-distro` depends on the shebang rewriting.

### Part 4: Enable the DNS redirect

Once Pi-hole answers queries, open `/data/adb/service.d/master-boot.sh` and set `PIHOLE_REDIRECT=1` at the top. Reboot (or run the script as root). Afterwards, from another device, test with `nslookup google.com <phone-ip>`; the query should appear in the Pi-hole Query Log immediately.

### Part 5: Point clients at Pi-hole

**Devices on your tailnet**

1. In the [Tailscale admin console](https://login.tailscale.com/admin/dns) go to **DNS → Global nameservers** and add the phone's Tailscale IP (`100.x.y.z`).
2. Enable **Override local DNS**.
3. Enable **Use with exit node** on that nameserver. Without it, a client that is using an exit node ignores this nameserver and falls back to a public one.
4. Disconnect and reconnect Tailscale on the client so it picks up the change.

The phone itself runs with `--accept-dns=false`, so it doesn't query itself. Note that this setting is tailnet-wide: if Pi-hole is down, every client using it loses DNS.

**Android's "Private DNS" setting on clients must be Off (or Automatic).** It speaks DNS-over-TLS (port 853), needs a hostname with a valid certificate, and doesn't accept an IP address, so it can't point at Pi-hole. While it is set to a fixed provider it also overrides the tailnet's DNS entirely.

### Verifying Pi-hole

```sh
# Is FTL running inside the container? (No output = not running)
proot-distro login ubuntu -- pgrep -l pihole-FTL

# From another machine on the LAN: expect 53 (dnsmasq, Pi-hole), 8080 (dashboard), 8022 (SSH)
nmap -A <phone-lan-ip>

# From a tailnet device: the query must show up in the Pi-hole Query Log
nslookup google.com <phone-tailscale-ip>
```

`pihole status` isn't a reliable check here. Inside PRoot it can print `Cannot open netlink socket: Permission denied` and red ✗ marks for the ports even though it also reports that FTL is listening on 5353. PRoot blocks the low-level socket it uses; the daemon is fine.

---

## Troubleshooting

| Symptom | Likely cause |
| ------- | ------------- |
| `avc: denied` in `dmesg` / `logcat` | SELinux blocking netlink or iptables calls. Patch only the denied domain with `magiskpolicy --live "permissive <domain>"` rather than a blanket `setenforce 0`. |
| `tailscale0` never appears | Daemon crashed or fell back silently. Check `logcat`, and confirm the binary matches your device's ABI. |
| Client shows exit node selected but has no internet; FORWARD counters stay at zero | The `ip rule ... iif tailscale0` entries are missing, or neither resolves a route (see step 4 of the boot script and the note on `main` vs. the per-interface table). Packets arrive but have no route to resolve. |
| `ts-input` counters climb but `ts-forward` stays at zero | Traffic is reaching the device as its _destination_, not passing through it. The client isn't routing through this node yet; look at the client side. |
| Client shows exit node "connected" but nothing routes | On non-rooted Android clients, check that battery optimization isn't throttling the Tailscale service and that no conflicting VPN or private-DNS app is active. |
| Complete internet loss ("no internet" Wi-Fi warning), fixed only by a full reboot (not a Wi-Fi toggle) | Possible `nf_conntrack` exhaustion under sustained exit-node traffic. Compare `/proc/sys/net/netfilter/nf_conntrack_count` with `nf_conntrack_max`. If it is pegged, raise the max, e.g. `echo 262144 > /proc/sys/net/netfilter/nf_conntrack_max`, and add that line to `master-boot.sh`. |
| `ping 8.8.8.8` works but `ping google.com` doesn't | DNS problem, not routing. If you enabled the Pi-hole redirect, first check that Pi-hole is running (or set `PIHOLE_REDIRECT=0` and reboot). Otherwise see [DNS troubleshooting](#dns-troubleshooting). |
| Pi-hole diagnosis shows red `Permission denied` errors for port 123 | FTL's built-in NTP server can't bind a privileged port. Disable it (Pi-hole Part 1, step 6). |
| "Cannot open gravity database for writing" | Wrong ownership on `/etc/pihole`, or FTL started before it was fixed. See [Blocklists and first-run fixes](#part-2-blocklists-and-first-run-fixes). |
| A newly added adlist shows a red error | The URL was pasted with Markdown brackets (`[url](url)`). Use the plain `https://...` address. |
| `chown: bad user 'pihole'` | You ran it in the Android root shell. The `pihole` user exists only inside Ubuntu (`proot-distro login ubuntu`). |
| `pihole status` shows `netlink socket: Permission denied` and red ✗ ports | Harmless PRoot limitation. Check with `pgrep -l pihole-FTL` instead. |
| Pi-hole didn't start after reboot (`pgrep` prints nothing) | Termux:Boot didn't run (battery set to anything but Unrestricted), or the script lacks the `export` lines or `-f`. See [Part 3](#part-3-start-pi-hole-at-boot-termuxboot). |
| `FTL started!` but dashboard and DNS are dead | FTL was launched without `-f` from a script, so PRoot closed the container when FTL daemonized. Use `pihole-FTL -f` with `nohup ... &`. |
| Tailnet client doesn't show up in the Query Log | Check, in order: the DNS redirect is on (`PIHOLE_REDIRECT=1`); the console nameserver has **Use with exit node** enabled; the client's Private DNS is Off. If it still times out, check that FTL accepts non-local clients (`pihole-FTL --config dns.listeningMode` should print `ALL`; set it with `pihole-FTL --config dns.listeningMode ALL` and restart FTL). |
| Home devices ignore Pi-hole | The ISP router's DHCP hands out `8.8.8.8`. Set static DNS per device or use your own router. See [Part 5](#part-5-point-clients-at-pi-hole). |
| `pkg update` / `pkg install` fail with "all mirrors bad" over SSH but work in Termux on-device | `sshd` was started from Magisk instead of Termux:Boot and lacks the `inet` group and app SELinux context. See [SSH access](#why-sshd-is-not-in-the-magisk-script). |
| `ip route get` fails with `Not a route` / `An error :-)` | Ran inside a PRoot container. PRoot's syscall interception doesn't provide working netlink sockets, so commands that need them (like `ip route get`) fail. Run the command from the host Android root shell instead; the route it adds (or the information it reports) is still visible to processes inside the container, since PRoot shares the host's network namespace. |

### DNS troubleshooting

If hostname resolution fails device-wide while raw-IP connectivity works, check in this order:

1. `dig google.com @8.8.8.8`. If this works, DNS traffic itself is fine and the problem is Android's automatic resolver selection.
2. Look at the device's Private DNS setting (under network/connection settings; the exact menu path varies by device and ROM). On "Automatic", Android may try DNS-over-TLS against your network's DHCP-assigned servers, which hangs if they don't support it. This is common on **CGNAT ISP connections**: if your router's WAN IP is in `100.64.0.0/10`, the ISP may hand out internal-only resolvers (also in that range) that LAN clients can't reach and that don't speak DoT.
3. **Fix at the router (preferred):** in the LAN-side DHCP settings, set static public DNS servers (`1.1.1.1`, `8.8.8.8`) instead of passing through the WAN-assigned ones. On many ISP-supplied routers these fields are locked; then use the on-device workaround below, or your own router.
4. **Workaround on the device:** Wi-Fi → network settings → Advanced → IP settings → Static, then set DNS 1 / DNS 2 to `8.8.8.8` / `1.1.1.1`.

This is unrelated to the kernel-routing setup. CGNAT on your ISP connection doesn't affect Tailscale itself, which works behind CGNAT via direct connections or DERP relays; it only affects Android's DNS server selection.

---

## Credits

- [Tailscale](https://github.com/tailscale/tailscale), the upstream project
- [android-kxxt/external_tailscale](https://github.com/android-kxxt/external_tailscale), the Android fwmark / IP-rule / go-iptables patches this setup depends on
- [Termux](https://github.com/termux) [Termux:Boot](https://github.com/termux/termux-boot) and [Termux:API](https://github.com/termux/termux-api)
- [proot-distro](https://github.com/termux/proot-distro)
- [Pi-hole](https://pi-hole.net/)

## Disclaimer

This runs a modified, community-patched build of Tailscale outside its officially supported deployment path, on a rooted device. Depending on your device you may also need SELinux policy exceptions (see [Troubleshooting](#troubleshooting)). Understand the security tradeoffs before offering this as an exit node to devices or people you don't fully trust.
