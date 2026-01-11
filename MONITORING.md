# 📊 Monitoring & Testing Commands

Quick reference guide for monitoring and testing the HelloSkyy H12 Fan Control system.

## 🔍 Real-Time Monitoring

### Watch Fan Speeds and CPU Temps Together

**Single command to watch both:**
```bash
watch -n 2 'echo "=== FAN SPEEDS ===" && ipmitool sensor | grep -i fan && echo "" && echo "=== CPU TEMPERATURES ===" && sensors | grep Tctl'
```

**Or separate terminals:**
```bash
# Terminal 1: Watch fan speeds
watch -n 2 'ipmitool sensor | grep -i fan'

# Terminal 2: Watch CPU temperatures
watch -n 2 'sensors | grep Tctl'
```

### Monitor Daemon Logs in Real-Time

```bash
journalctl -f -t hs-fan-daemon
```

This shows:
- Temperature readings
- Fan level changes
- PWM adjustments
- Any errors or warnings

## 📈 Current Status Commands

### Check Service Status
```bash
systemctl status hs-fan-daemon
```

### View Recent Logs (Last 20 entries)
```bash
journalctl -t hs-fan-daemon -n 20
```

### Check Current Fan Mode
```bash
ipmitool raw 0x30 0x45 0x00
```
Should return: `01` (Full Speed mode)

### Get All Fan Speeds
```bash
ipmitool sensor | grep -i fan
```

### Get All CPU Temperatures
```bash
sensors | grep Tctl
```

### Get Maximum CPU Temperature (what daemon uses)
```bash
sensors | grep Tctl | awk '{print $2}' | sed 's/+//;s/°C//' | sort -n | tail -1
```

## 🧪 Testing Commands

### Test Fan Response to Temperature Changes

**1. Check current state:**
```bash
echo "Current CPU Temp:" && sensors | grep Tctl | head -1 && echo "Current Fan Speeds:" && ipmitool sensor | grep -i fan | head -3
```

**2. Generate CPU load to increase temperature:**
```bash
# Install stress-ng if needed: apt install stress-ng
stress-ng --cpu 0 --timeout 60s
```

**3. Watch fan speeds increase:**
```bash
watch -n 1 'ipmitool sensor | grep -i fan | head -3'
```

**4. Stop stress and watch fans slow down:**
```bash
# Press Ctrl+C to stop stress-ng, then watch:
watch -n 2 'sensors | grep Tctl && echo "" && ipmitool sensor | grep -i fan | head -3'
```

### Test Manual PWM Control (Advanced)

**Set fan to 50% manually:**
```bash
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x32
```

**Set fan to 30% manually:**
```bash
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x1E
```

**Set fan to 100% manually:**
```bash
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x64
```

**Note:** The daemon will override manual settings on its next polling cycle (every 5 seconds).

## 📊 One-Line Status Summary

**Complete system status:**
```bash
echo "=== FAN CONTROL STATUS ===" && systemctl is-active hs-fan-daemon && echo "" && echo "=== BMC FAN MODE ===" && ipmitool raw 0x30 0x45 0x00 && echo "" && echo "=== MAX CPU TEMP ===" && sensors | grep Tctl | awk '{print $2}' | sed 's/+//;s/°C//' | sort -n | tail -1 && echo "°C" && echo "" && echo "=== FAN SPEEDS ===" && ipmitool sensor | grep -i fan | head -3
```

## 🔄 Testing Update Process

**Check if update is available:**
```bash
# This will show if files have changed
curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/update.sh | bash
```

**Or use deploy script (idempotent):**
```bash
curl -sSL https://raw.githubusercontent.com/helloskyy-io/skyy-h12-fanctl/main/deploy.sh | bash
```

## 🎯 Quick Health Check

**Run this to verify everything is working:**
```bash
echo "Service Status:" && systemctl is-active hs-fan-daemon && echo "" && echo "Recent Activity:" && journalctl -t hs-fan-daemon -n 5 --no-pager && echo "" && echo "Current Temp & Fans:" && sensors | grep Tctl | head -1 && ipmitool sensor | grep -i fan | head -1
```

## 💡 Pro Tips

1. **Watch logs while testing:** Keep `journalctl -f -t hs-fan-daemon` running in one terminal while you test
2. **Temperature ranges:** 
   - < 35°C = 20% fan (idle)
   - 35-39°C = 30% fan
   - 40-44°C = 40% fan
   - 45-49°C = 50% fan
   - etc.
3. **Hysteresis:** Fans won't change speed immediately - there's a 2-5°C buffer to prevent flapping
4. **Polling interval:** Daemon checks every 5 seconds (configurable via POLL_INTERVAL)

