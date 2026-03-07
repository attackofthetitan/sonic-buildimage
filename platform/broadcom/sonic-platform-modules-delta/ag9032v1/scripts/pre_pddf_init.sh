#!/bin/bash

# Pre-PDDF initialization script for Delta AG9032V1
#
# PDDF creates the PCA9547 mux on bus 1 with dynamic bus allocation
# (no platform_data). The mux channels get the next available bus numbers.
# For correct operation, we need exactly buses 0 and 1 to exist before
# the mux is created, so channels map to buses 2-9 as pddf-device.json expects.
#
# This script:
# 1. Ensures i2c-i801 and i2c-ismt are loaded (creating buses 0 and 1)
# 2. Removes any i2c-isch bus that could shift mux channel numbering
# 3. Verifies the PCA9547 mux is accessible on bus 1

# Ensure base I2C adapters are loaded
modprobe i2c-i801 2>/dev/null
modprobe i2c-ismt 2>/dev/null
modprobe i2c-dev 2>/dev/null

# Unload i2c-isch if loaded - it can create spurious buses that shift
# the PCA9547 mux channel numbering
if lsmod | grep -q i2c_isch; then
    echo "pre_pddf_init: Removing i2c-isch to prevent bus number conflicts"
    rmmod i2c-isch 2>/dev/null
fi

# Unload i2c-mux-gpio if loaded - not needed and can create extra buses
if lsmod | grep -q i2c_mux_gpio; then
    echo "pre_pddf_init: Removing i2c-mux-gpio to prevent bus number conflicts"
    rmmod i2c-mux-gpio 2>/dev/null
fi

# Verify bus 1 exists (i2c-ismt adapter, where PCA9547 lives)
if [ ! -d /sys/bus/i2c/devices/i2c-1 ]; then
    echo "pre_pddf_init: WARNING - i2c bus 1 does not exist"
    exit 1
fi

# Check that bus 2 does NOT already exist (would mean something already
# allocated it, and mux channels would get higher numbers)
if [ -d /sys/bus/i2c/devices/i2c-2 ]; then
    echo "pre_pddf_init: WARNING - i2c bus 2 already exists before mux creation"
    echo "pre_pddf_init: Mux channel numbering may be incorrect"
fi

echo "pre_pddf_init: Bus state verified, ready for PDDF initialization"
exit 0
