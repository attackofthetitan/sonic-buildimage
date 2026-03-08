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
# 2. Removes any conflicting modules that could shift mux channel numbering
# 3. Waits for bus 1 to appear and verifies bus state

# Ensure base I2C adapters are loaded
modprobe i2c-i801 2>/dev/null
modprobe i2c-ismt 2>/dev/null
modprobe i2c-dev 2>/dev/null

# Remove conflicting old platform drivers if loaded - these create I2C
# devices (PCA9547 mux, CPLD muxes) that conflict with PDDF device creation
for mod in delta_ag9032v1_platform delta_ag9032v1_cpupld dni_ag9032v1_psu dni_emc2305; do
    if lsmod | grep -q "${mod//-/_}"; then
        echo "pre_pddf_init: Removing conflicting module $mod"
        rmmod "$mod" 2>/dev/null
    fi
done

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

# Wait for bus 1 to appear (i2c-ismt may need time to probe)
for i in $(seq 1 10); do
    [ -d /sys/bus/i2c/devices/i2c-1 ] && break
    echo "pre_pddf_init: Waiting for i2c bus 1... ($i/10)"
    sleep 0.5
done

# Verify bus 1 exists (i2c-ismt adapter, where PCA9547 lives)
if [ ! -d /sys/bus/i2c/devices/i2c-1 ]; then
    echo "pre_pddf_init: ERROR - i2c bus 1 does not exist after waiting"
    exit 1
fi

# Check that bus 2 does NOT already exist (would mean something already
# allocated it, and mux channels would get higher numbers)
if [ -d /sys/bus/i2c/devices/i2c-2 ]; then
    echo "pre_pddf_init: WARNING - i2c bus 2 already exists before mux creation"
    echo "pre_pddf_init: Mux channel numbering may be incorrect"
fi

# Pre-create the PCA9547 mux on bus 1 so child buses 2-9 exist
# before PDDF's pddfparse.py tries to create devices on them.
# Without this, pddfparse.py's mux_parse() creates the MUX then
# immediately tries to create CPLD1 on bus 2 — but the pca954x
# driver probe (which creates child bus adapters) may not complete
# in time, causing i2c_get_adapter(2) to return NULL and panic.
#
# When PDDF later tries to re-create this MUX via pddf_mux_module,
# i2c_new_client_device() returns ERR_PTR (device already exists).
# mux_parse() ignores this error (create_mux_device() returns None)
# and proceeds to iterate channels — where buses now already exist.
modprobe i2c-mux-pca954x 2>/dev/null
if [ ! -d /sys/bus/i2c/devices/i2c-2 ]; then
    echo "pre_pddf_init: Pre-creating PCA9547 mux on bus 1"
    echo pca9547 0x71 > /sys/bus/i2c/devices/i2c-1/new_device 2>/dev/null

    # Wait for MUX child buses to appear (pca954x driver probe creates them)
    for i in $(seq 1 20); do
        [ -d /sys/bus/i2c/devices/i2c-2 ] && break
        sleep 0.5
    done

    if [ ! -d /sys/bus/i2c/devices/i2c-2 ]; then
        echo "pre_pddf_init: ERROR - MUX child bus 2 did not appear after 10s"
        exit 1
    fi
    echo "pre_pddf_init: MUX child buses created successfully"
fi

echo "pre_pddf_init: Bus state verified, ready for PDDF initialization"
exit 0
