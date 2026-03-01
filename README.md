# HelloSkyy H12 Fan Control

Temperature-based fan control for **Supermicro H12 series** motherboards (Proxmox, Ubuntu, Debian). The daemon reads CPU temperature and sets fan PWM via IPMI so you get cooler, quieter behavior than the default BMC curve.

**Compatibility:** Supermicro H12 series only. Other Supermicro or non-Supermicro boards are not supported.

---

## 1. Install or update (one command)

The deploy script is **idempotent**: use the same command for first install and for updates. It installs the daemon script and, only if missing, the systemd service file. It does **not** overwrite your existing service file so your tuning is preserved.

**On the server** (use `sudo` if you are not root):

```bash
curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | sudo bash
```

Requires `git` (the script clones the repo into a temp dir, uses it, then deletes it—nothing is left on disk except the installed files).

**Installed locations:**

| What            | Where |
|-----------------|--------|
| Daemon script   | `/usr/local/sbin/hs-fan-daemon.sh` |
| Service unit    | `/etc/systemd/system/hs-fan-daemon.service` (created only if it doesn’t exist) |

---

## 2. Apply latest config (overwrite service file and restart)

When you want the **new default config** from the repo (e.g. after an update), overwrite the service file and restart. Use **one** of the following.

**A) You did not clone the repo** (e.g. you used the curl install above):

```bash
curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/systemd/hs-fan-daemon.service.template -o /etc/systemd/system/hs-fan-daemon.service
systemctl daemon-reload
systemctl restart hs-fan-daemon
```

(Omit `sudo` if you are already root.)

**B) You have a local clone of the repo:**

```bash
cp systemd/hs-fan-daemon.service.template /etc/systemd/system/hs-fan-daemon.service
systemctl daemon-reload
systemctl restart hs-fan-daemon
```

Then edit `/etc/systemd/system/hs-fan-daemon.service` (or `systemctl edit hs-fan-daemon.service`) to set your preferred values (e.g. `FAN_MIN_LEVEL`).

---

## 3. Manual install (when you clone the repo locally)

```bash
git clone https://github.com/helloskyy-io/skyy-h12-fanctl.git
cd skyy-h12-fanctl
```

Install prerequisites and the daemon:

```bash
apt update && apt install -y ipmitool lm-sensors
install -m 755 scripts/hs-fan-daemon.sh /usr/local/sbin/hs-fan-daemon.sh
```

Install the systemd unit (only if you don’t already have one):

```bash
[ -f /etc/systemd/system/hs-fan-daemon.service ] || install -m 644 systemd/hs-fan-daemon.service.template /etc/systemd/system/hs-fan-daemon.service
systemctl daemon-reload
systemctl enable hs-fan-daemon.service
systemctl start hs-fan-daemon.service
```

---

## 4. Common commands

| Command | What it does |
|--------|----------------|
| `systemctl status hs-fan-daemon` | Show whether the daemon is running. |
| `systemctl start hs-fan-daemon` | Start the daemon. |
| `systemctl stop hs-fan-daemon` | Stop the daemon (BMC may then run fans at its own default). |
| `systemctl restart hs-fan-daemon` | Restart after changing config. |
| `journalctl -f -t hs-fan-daemon` | Stream daemon logs (temp, fan level, PWM). |
| `systemctl edit hs-fan-daemon.service` | Override config (drop-in); then run `daemon-reload` and `restart`. |
| `ipmitool sensor \| grep -i fan` | Show fan RPM (run as root if needed). |
| `sensors \| grep Tctl` | Show CPU temps the daemon uses. |

---

## 5. Configuration

**Where it lives:** `/etc/systemd/system/hs-fan-daemon.service` (or overrides via `systemctl edit hs-fan-daemon.service`). Editing the repo template has no effect until you overwrite the installed file (see section 2).

**Options:**

| Variable | Meaning | Default |
|----------|---------|---------|
| **FAN_MIN_LEVEL** | Minimum fan % (20, 30, or 40). Idle never goes below this. | 40 |
| **POLL_INTERVAL** | Seconds between temperature checks. | 5 |
| **LOG_TAG** | syslog / journalctl tag. | hs-fan-daemon |
| **FAN_ZONES** | BMC zones to control (e.g. `0x00` or `0x00,0x01,0x02`). | 0x00,0x01,0x02 |

On some boards (especially with low-RPM fans), the BMC may override 20% or 30% to 100%; 40% is a safe default. Single-CPU H12: if the daemon’s PWM seems ignored, try `FAN_ZONES=0x00` only.

---

## 6. How it works

- Reads **max Tctl** across all EPYC CPUs (`sensors`), every **POLL_INTERVAL** seconds.
- Uses a **hysteresis** curve so fan level goes up/down only when temp crosses thresholds (avoids flapping).
- Sends PWM to the BMC via IPMI. BMC must be in **Full Speed (0x01)**; the daemon sets this on start.

**Fan curve (example):** &lt;35°C → 20%*, 35–39°C → 30%, … up to ≥70°C → 100%.  
\*Actual minimum is **FAN_MIN_LEVEL** (default 40%).

---

## 7. Troubleshooting

**Check compatibility:** `dmidecode -t baseboard | grep -i "product name"` — must be H12 (e.g. H12SSL, H12DSI).

**IPMI not working:** Load modules if needed: `modprobe ipmi_msghandler ipmi_devintf ipmi_si`. Then `ipmitool mc info`.

**Sensors missing:** `apt install lm-sensors -y` then `sensors-detect` (answer yes).

**Daemon not starting:** `systemctl status hs-fan-daemon` and `journalctl -u hs-fan-daemon -n 50`. Run by hand: `/usr/local/sbin/hs-fan-daemon.sh` (as root).

**Fans not following daemon:**  
1. `ipmitool raw 0x30 0x45 0x00` → should be `01` (Full Speed).  
2. If not: `ipmitool raw 0x30 0x45 0x01 0x01`.  
3. On single-CPU H12, try `FAN_ZONES=0x00` in the service file and restart.

**Config drift warning after deploy:** The script compares the repo template to your installed service file. If they differ (e.g. new or removed options), it prints a warning. Overwrite the service file with the template (section 2) and re-apply your edits, or merge the new options by hand.

More detail: [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

---

## Project layout

```
skyy-h12-fanctl/
├── scripts/hs-fan-daemon.sh
├── systemd/hs-fan-daemon.service.template
├── deploy.sh
├── update.sh
├── README.md
└── TROUBLESHOOTING.md
```

**License:** MIT. See [LICENSE](LICENSE).

**Repo:** https://github.com/helloskyy-io/skyy-h12-fanctl
