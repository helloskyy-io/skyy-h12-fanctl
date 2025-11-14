# 🖥️ HelloSkyy H12 Fan Control

Intelligent fan control system **specifically designed for Supermicro H12 series motherboards** running Proxmox, Ubuntu, or Debian. This project provides automated temperature-based fan speed management optimized for EPYC multi-CPU systems where default fan curves often run too hot.

**⚠️ Important:** This solution is **only compatible with Supermicro H12 series motherboards**. Use at your own risk on other Supermicro models or non-Supermicro hardware.

## 📋 Overview

This fan control system provides intelligent, temperature-based fan speed management **specifically for Supermicro H12 series motherboards**. The solution uses Supermicro-specific IPMI commands that are only compatible with H12 series hardware.

**Important:** This solution **REQUIRES** the Supermicro BMC to be set to **Full Speed mode (0x01)**. The daemon automatically sets this mode on startup and takes full control of fan speeds via raw PWM commands.

**Fan Control Daemon** (`hs-fan-daemon`) - Continuously monitors CPU temperatures and adjusts fan speeds using a hysteresis-based curve to prevent fan flapping. The daemon automatically sets the BMC to Full Speed mode (0x01) on startup, which is required for PWM control to function properly.

## ⚠️ Before You Begin

**Compatibility:** This solution is **only compatible with Supermicro H12 series motherboards**. It uses H12-specific IPMI commands and will not work on other Supermicro models or non-Supermicro hardware.

**This is a custom fan control solution.** If your server is running a bit hot, you may want to try the standard Supermicro settings first:

1. **Try Heavy I/O Mode (0x04) first** - This is a standard Supermicro setting that may provide adequate cooling:
   ```bash
   ipmitool raw 0x30 0x45 0x01 0x04
   ```
   Monitor temperatures for a while. If this works, you don't need this custom solution.

2. **If Heavy I/O mode isn't sufficient**, then install this custom solution, which:
   - Requires Full Speed mode (0x01) to enable PWM control
   - Provides intelligent, temperature-based fan speed management
   - Automatically adjusts fan speeds based on CPU temperature

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

3. **Install script:**
   ```bash
   install -m 755 scripts/hs-fan-daemon.sh /usr/local/sbin/hs-fan-daemon.sh
   ```

4. **Install systemd service:**
   ```bash
   install -m 644 systemd/hs-fan-daemon.service /etc/systemd/system/
   ```

5. **Enable and start service:**
   ```bash
   systemctl daemon-reload
   systemctl enable hs-fan-daemon.service
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

Expected output: `01` (Full Speed mode - required for PWM control)

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
| `01` | Full Speed | ✔ "Full Speed" | **REQUIRED for this solution** - Enables PWM control |
| `02` | Optimal | ✔ "Optimal" | Default, often too hot for EPYC |
| `03` | Unknown | ❌ Not shown | Invalid on H12 |
| `04` | Heavy I/O | ✔ "Heavy I/O" | Standard setting - try this first if server runs hot |

**Important Notes:**
- **Mode 0x01 (Full Speed)** is **REQUIRED** for this custom fan control solution to work. The daemon automatically sets this mode on startup.
- **Mode 0x04 (Heavy I/O)** is a standard Supermicro setting you can try **before** installing this solution. If Heavy I/O mode doesn't provide adequate cooling, then use this custom solution which requires Full Speed mode.
- The BMC GUI only shows 3 modes, but firmware supports more.

## 📊 Configuration

### Environment Variables

You can override default settings via systemd environment variables:

**For `hs-fan-daemon.service`:**
```ini
Environment=POLL_INTERVAL=5        # Polling interval in seconds
Environment=LOG_TAG=hs-fan-daemon  # Syslog tag
Environment=FAN_ZONE=0x00          # Fan zone (0x00 = all fans)
Environment=FAN_MODE=0x01          # Fan mode (0x01 = Full Speed, REQUIRED)
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

### Compatibility Check

**First, verify you have a Supermicro H12 series motherboard:**

1. **Check motherboard model:**
   ```bash
   dmidecode -t baseboard | grep -i "product name"
   ```
   Should show an H12 series model (e.g., H12SSL, H12DSI, H12DSU, etc.)

2. **If you don't have an H12 series motherboard:**
   - This solution will **not work** on your hardware
   - The IPMI commands are H12-specific
   - You'll need a different solution for your motherboard model

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

1. **Verify fan mode is set to Full Speed (REQUIRED):**
   ```bash
   ipmitool raw 0x30 0x45 0x00
   ```
   Should return `01` (Full Speed mode - required for PWM control)

2. **Manually set fan mode to Full Speed:**
   ```bash
   ipmitool raw 0x30 0x45 0x01 0x01
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
│   └── hs-fan-daemon.sh          # Main fan control daemon (includes mode initialization)
├── systemd/
│   └── hs-fan-daemon.service     # Daemon systemd service
├── deploy.sh                      # Automated deployment script
├── README.md                      # This file
├── LICENSE                        # MIT License
└── .gitignore                     # Git ignore rules
```

## 🤝 Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

The MIT License allows you to use, modify, distribute, and sell this software for any purpose, including commercial use, with minimal restrictions. You are free to use this code in any way you want.

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

