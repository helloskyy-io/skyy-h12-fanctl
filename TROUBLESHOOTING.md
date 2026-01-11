# 🔧 Troubleshooting Fan Control Issues

## Problem: Fans Not Responding to PWM Commands

If the daemon is sending PWM commands but fans aren't responding, try these steps:

### Step 1: Verify Current Fan Speeds

```bash
ipmitool sensor | grep -i fan
```

Note the actual RPM values.

### Step 2: Test Manual PWM Control

Try setting PWM manually to verify the command works:

```bash
# Set to 50% (0x32)
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x32

# Wait 10 seconds, then check fan speeds
sleep 10
ipmitool sensor | grep -i fan
```

**If this works:** The command is correct, but there might be a timing or zone issue.

**If this doesn't work:** The IPMI command or zone might be wrong for your board.

### Step 3: Check Fan Zones

Some H12 boards have multiple fan zones. Try different zones:

```bash
# Zone 0x00 (all fans - default)
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x32

# Zone 0x01 (zone 1)
ipmitool raw 0x30 0x70 0x66 0x01 0x01 0x32

# Zone 0x02 (zone 2)
ipmitool raw 0x30 0x70 0x66 0x01 0x02 0x32
```

Watch fan speeds after each command to see which zone controls your fans.

### Step 4: Check BMC Override Settings

Some Supermicro boards have BMC settings that override PWM. Check:

```bash
# Check current fan mode
ipmitool raw 0x30 0x45 0x00

# Should return 01 (Full Speed mode)
# If it's not 01, set it:
ipmitool raw 0x30 0x45 0x01 0x01
```

### Step 5: Verify IPMI Command Format

Some H12 boards might need a slightly different command. Try:

```bash
# Standard command (what we use)
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x32

# Alternative format (some boards)
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x32 0x00
```

### Step 6: Check for Hardware Minimums

Some fans have hardware minimum speeds (often 30-40%). Test:

```bash
# Try 30% (0x1E)
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x1E
sleep 10
ipmitool sensor | grep -i fan

# Try 40% (0x28)
ipmitool raw 0x30 0x70 0x66 0x01 0x00 0x28
sleep 10
ipmitool sensor | grep -i fan
```

If 30% works but 20% doesn't, your fans have a hardware minimum.

### Step 7: Check BMC Firmware Version

Some BMC firmware versions have bugs with PWM control:

```bash
ipmitool mc info | grep -i "firmware\|version"
```

### Step 8: Check System Logs

Look for IPMI errors:

```bash
dmesg | grep -i ipmi
journalctl | grep -i ipmi | tail -20
```

## Common Issues & Solutions

### Issue: Fans stuck at 100% despite PWM commands

**Possible causes:**
1. BMC override enabled
2. Wrong fan zone
3. BMC firmware bug
4. Temperature sensors triggering safety mode

**Solutions:**
- Verify fan mode is 0x01 (Full Speed)
- Try different fan zones
- Check if there's a temperature threshold override
- Update BMC firmware if available

### Issue: Fans don't go below 30-40%

**Cause:** Hardware minimum fan speed

**Solution:** This is normal. Adjust the fan curve to start at 30% or 40% instead of 20%.

### Issue: PWM commands work manually but not from daemon

**Possible causes:**
1. Timing issue (commands too frequent)
2. Service running as wrong user
3. Permission issue

**Solutions:**
- Check service is running as root: `ps aux | grep hs-fan-daemon`
- Check logs for errors: `journalctl -t hs-fan-daemon -n 50`
- Increase POLL_INTERVAL if commands are too frequent

## Diagnostic Script

Run this to gather diagnostic information:

```bash
echo "=== BMC INFO ===" && \
ipmitool mc info | grep -E "Firmware|Version" && \
echo "" && \
echo "=== FAN MODE ===" && \
ipmitool raw 0x30 0x45 0x00 && \
echo "" && \
echo "=== FAN SPEEDS ===" && \
ipmitool sensor | grep -i fan && \
echo "" && \
echo "=== CPU TEMPS ===" && \
sensors | grep Tctl && \
echo "" && \
echo "=== DAEMON STATUS ===" && \
systemctl status hs-fan-daemon --no-pager -l | head -10 && \
echo "" && \
echo "=== RECENT LOGS ===" && \
journalctl -t hs-fan-daemon -n 10 --no-pager
```

