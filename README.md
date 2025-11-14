# 🖥️ HelloSkyy H12 Fan Control

Intelligent fan control system for Supermicro H12 motherboards running Proxmox, Ubuntu, or Debian. This project provides automated temperature-based fan speed management optimized for EPYC multi-CPU systems where default fan curves often run too hot.

## 📋 Overview

This fan control system consists of two main components:

1. **Mode Initialization Service** (`hs-fan-mode-init`) - Sets the Supermicro BMC to "Heavy I/O" mode (0x04) at boot, which is optimal for EPYC thermals
2. **Fan Control Daemon** (`hs-fan-daemon`) - Continuously monitors CPU temperatures and adjusts fan speeds using a hysteresis-based curve to prevent fan flapping

### Key Features

- ✅ Automatic temperature-based fan speed control
- ✅ Hysteresis logic prevents rapid fan speed oscillations
- ✅ Monitors all CPU cores and uses maximum temperature
- ✅ Safe fallback: BMC takes over if daemon stops
- ✅ Systemd integration for automatic startup
- ✅ Comprehensive logging via syslog/journalctl
- ✅ One-command deployment

## 🚀 Quick Installation

### Automated Deployment (Recommended)

Run this single command on your Proxmox/Ubuntu/Debian server:

```bash
curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | bash
```

Or using `wget`:

```bash
wget -qO- https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | bash
```

The deployment script will:
- Install prerequisites (`ipmitool`, `lm-sensors`)
- Install the fan control scripts
- Configure systemd services
- Enable and start the services automatically

### Manual Installation

If you prefer manual installation:

1. **Clone the repository:**
   ```bash
   git clone git@github.com:helloskyy-io/skyy-h12-fanctl.git
   cd skyy-h12-fanctl
   ```

2. **Install prerequisites:**
   ```bash
   apt update
   apt install ipmitool lm-sensors -y
   ```

3. **Install scripts:**
   ```bash
   install -m 755 scripts/hs-fan-daemon.sh /usr/local/sbin/hs-fan-daemon.sh
   install -m 755 scripts/hs-fan-mode-init.sh /usr/local/sbin/hs-fan-mode-init.sh
   ```

4. **Install systemd services:**
   ```bash
   install -m 644 systemd/hs-fan-mode-init.service /etc/systemd/system/
   install -m 644 systemd/hs-fan-daemon.service /etc/systemd/system/
   ```

5. **Enable and start services:**
   ```bash
   systemctl daemon-reload
   systemctl enable hs-fan-mode-init.service
   systemctl enable hs-fan-daemon.service
   systemctl start hs-fan-mode-init.service
   systemctl start hs-fan-daemon.service
   ```

## 🔍 Verification

### Check Service Status

```bash
systemctl status hs-fan-daemon
```

### View Live Logs

```bash
journalctl -f -t hs-fan-daemon
```

### Check Current Fan Mode

```bash
ipmitool raw 0x30 0x45 0x00
```

Expected output: `04` (Heavy I/O mode)

### Monitor Fan Speeds

```bash
ipmitool sensor | grep -i fan
```

### Check CPU Temperatures

```bash
sensors | grep -i cpu
```

Or:

```bash
ipmitool sensor | grep -i CPU
```

## ⚙️ How It Works

### Fan Speed Curve

The daemon uses a hysteresis-based fan curve to prevent rapid oscillations:

| Temperature Range | Fan Speed | Notes |
|------------------|-----------|-------|
| < 45°C | 40% | Low power, quiet operation |
| 45-49°C | 50% | Light load |
| 50-54°C | 60% | Moderate load |
| 55-59°C | 70% | Increased cooling |
| 60-64°C | 80% | High load |
| 65-69°C | 90% | Very high load |
| ≥ 70°C | 100% | Maximum cooling |

**Hysteresis Logic:**
- To increase speed: temperature must exceed the upper threshold
- To decrease speed: temperature must drop below a lower threshold
- This prevents fan flapping between adjacent speed levels

### Temperature Monitoring

- Reads maximum `Tctl` temperature across all EPYC CPUs using `sensors`
- Polls every 5 seconds (configurable)
- Uses integer temperature values for decision making

### IPMI Commands

The system uses Supermicro raw IPMI commands:

- **Set fan mode:** `ipmitool raw 0x30 0x45 0x01 <mode>`
- **Read fan mode:** `ipmitool raw 0x30 0x45 0x00`
- **Set PWM:** `ipmitool raw 0x30 0x70 0x66 0x01 <zone> <pwm>`

### Supermicro Fan Modes

| Hex | Mode | GUI Label | Notes |
|-----|------|-----------|-------|
| `00` | Unknown | ❌ Not shown | Invalid on H12 |
| `01` | Full Speed | ✔ "Full Speed" | Always 100% |
| `02` | Optimal | ✔ "Optimal" | Default, often too hot for EPYC |
| `03` | Unknown | ❌ Not shown | Invalid on H12 |
| `04` | Heavy I/O | ✔ "Heavy I/O" | **Recommended for EPYC** |

**Note:** The BMC GUI only shows 3 modes, but firmware supports more. Mode 0x04 is optimal for EPYC systems but may not display correctly in the web UI.

## 📊 Configuration

### Environment Variables

You can override default settings via systemd environment variables:

**For `hs-fan-daemon.service`:**
```ini
Environment=POLL_INTERVAL=5        # Polling interval in seconds
Environment=LOG_TAG=hs-fan-daemon  # Syslog tag
Environment=FAN_ZONE=0x00          # Fan zone (0x00 = all fans)
```

**For `hs-fan-mode-init.service`:**
```ini
Environment=FAN_MODE=0x04          # Fan mode (0x04 = Heavy I/O)
Environment=IPMITOOL_BIN=/usr/bin/ipmitool
```

To modify, edit the service file:
```bash
systemctl edit hs-fan-daemon.service
```

Then add:
```ini
[Service]
Environment=POLL_INTERVAL=10
```

Reload and restart:
```bash
systemctl daemon-reload
systemctl restart hs-fan-daemon
```

## 🛠️ Management Commands

### Start/Stop/Restart

```bash
# Stop the daemon
systemctl stop hs-fan-daemon

# Start the daemon
systemctl start hs-fan-daemon

# Restart the daemon
systemctl restart hs-fan-daemon

# Disable auto-start on boot
systemctl disable hs-fan-daemon

# Re-enable auto-start on boot
systemctl enable hs-fan-daemon
```

### View Logs

```bash
# Last 50 log entries
journalctl -t hs-fan-daemon -n 50

# Follow logs in real-time
journalctl -f -t hs-fan-daemon

# Logs since boot
journalctl -t hs-fan-daemon -b

# Logs from last hour
journalctl -t hs-fan-daemon --since "1 hour ago"
```

### Manual Testing

Test the daemon manually (will run in foreground):

```bash
/usr/local/sbin/hs-fan-daemon.sh
```

Press `Ctrl+C` to stop.

## 🔧 Troubleshooting

### IPMI Not Accessible

If `ipmitool mc info` fails:

1. **Check IPMI kernel module:**
   ```bash
   lsmod | grep ipmi
   ```

2. **Load IPMI modules:**
   ```bash
   modprobe ipmi_msghandler
   modprobe ipmi_devintf
   modprobe ipmi_si
   ```

3. **Verify BMC is accessible:**
   ```bash
   ipmitool mc info
   ```

### Sensors Not Found

If `sensors` command fails:

1. **Install lm-sensors:**
   ```bash
   apt install lm-sensors -y
   ```

2. **Detect sensors:**
   ```bash
   sensors-detect
   ```
   (Answer "yes" to all prompts)

3. **Verify sensors:**
   ```bash
   sensors
   ```

### Daemon Not Starting

1. **Check service status:**
   ```bash
   systemctl status hs-fan-daemon
   ```

2. **Check logs for errors:**
   ```bash
   journalctl -u hs-fan-daemon -n 50
   ```

3. **Verify script permissions:**
   ```bash
   ls -l /usr/local/sbin/hs-fan-daemon.sh
   ```
   Should show `-rwxr-xr-x`

4. **Test script manually:**
   ```bash
   sudo /usr/local/sbin/hs-fan-daemon.sh
   ```

### Fans Not Responding

1. **Verify fan mode is set:**
   ```bash
   ipmitool raw 0x30 0x45 0x00
   ```
   Should return `04`

2. **Manually set fan mode:**
   ```bash
   ipmitool raw 0x30 0x45 0x01 0x04
   ```

3. **Check if PWM commands work:**
   ```bash
   # Set to 50% (0x32)
   ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x32
   ```

4. **Verify fan speeds change:**
   ```bash
   watch -n 1 'ipmitool sensor | grep -i fan'
   ```

### Temperature Readings Incorrect

1. **Verify sensors are detecting CPUs:**
   ```bash
   sensors | grep Tctl
   ```

2. **Check for multiple CPU sockets:**
   ```bash
   sensors | grep -E "CPU|Tctl"
   ```

3. **The daemon uses the maximum Tctl across all CPUs, which is correct for multi-socket systems.**

## 📈 Performance Expectations

### EPYC Temperature Guidelines

- **Idle:** 35-55°C (acceptable)
- **Under load:** 65-75°C (normal)
- **Sustained >80°C:** Consider improving cooling

### After Setting New Fan Mode

1. Wait 60 seconds for fans to adjust
2. Check fan speeds:
   ```bash
   ipmitool sensor | grep -i fan
   ```
3. Check CPU temperatures:
   ```bash
   sensors | grep -i cpu
   ```

## 🔐 Security Notes

- Scripts must run as root to access IPMI and sensors
- Services are configured to restart automatically on failure
- If the daemon stops, the BMC will eventually take over (usually ramps fans up for safety)
- No network exposure - all operations are local

## 📝 Project Structure

```
skyy-h12-fanctl/
├── scripts/
│   ├── hs-fan-daemon.sh          # Main fan control daemon
│   └── hs-fan-mode-init.sh       # Fan mode initialization script
├── systemd/
│   ├── hs-fan-daemon.service     # Daemon systemd service
│   └── hs-fan-mode-init.service  # Mode init systemd service
├── deploy.sh                      # Automated deployment script
├── README.md                      # This file
└── .gitignore                     # Git ignore rules
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

[Add your license here]

## 🔗 References

- [Supermicro IPMI Documentation](https://www.supermicro.com/en/support/faqs/faq.cfm?faq=27220)
- [IPMI Tool Documentation](https://github.com/ipmitool/ipmitool)
- [LM Sensors Documentation](https://www.kernel.org/doc/html/latest/hwmon/lm_sensors.html)

## 💡 Tips

- Monitor logs during initial deployment to ensure proper operation
- Test fan response by running CPU stress tests: `stress-ng --cpu 0 --timeout 60s`
- For multi-socket systems, the daemon correctly uses maximum temperature across all CPUs
- The hysteresis logic prevents unnecessary fan speed changes during temperature fluctuations

---

**Maintained by:** HelloSkyy  
**Repository:** https://github.com/helloskyy-io/skyy-h12-fanctl

