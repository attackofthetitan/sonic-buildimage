#!/bin/bash

# Pre-PDDF initialization script for Delta AG9032V1
#
# The PCA9547 mux is on the iSMT adapter. pddf-device.json expects:
#   bus 0 = i2c-i801
#   bus 1 = i2c-ismt (where PCA9547 lives at 0x71)
#   buses 2-9 = PCA9547 mux channels
#
# Kernel module load order is non-deterministic, so we must rmmod
# both adapters and reload in the correct order to guarantee
# i801=bus0, ismt=bus1. Then we pre-create the PCA9547 mux so
# child buses exist before PDDF's pddfparse.py tries to create
# devices on them.

# Remove conflicting old platform drivers if loaded
for mod in delta_ag9032v1_platform delta_ag9032v1_cpupld dni_ag9032v1_psu dni_emc2305; do
    lsmod | grep -q "${mod//-/_}" && rmmod "$mod" 2>/dev/null
done

# Remove spurious bus-creating modules
for mod in i2c_isch i2c_mux_gpio; do
    lsmod | grep -q "$mod" && rmmod "$mod" 2>/dev/null
done

# Force deterministic bus numbering by removing both adapters
# and reloading in the correct order
rmmod i2c_ismt 2>/dev/null
rmmod i2c_i801 2>/dev/null
sleep 0.5
modprobe i2c-i801    # → bus 0
modprobe i2c-ismt    # → bus 1
modprobe i2c-dev 2>/dev/null

# Wait for bus 1 (iSMT) to appear
for i in $(seq 1 10); do
    [ -d /sys/bus/i2c/devices/i2c-1 ] && break
    sleep 0.5
done

if [ ! -d /sys/bus/i2c/devices/i2c-1 ]; then
    echo "pre_pddf_init: ERROR - bus 1 not found"
    exit 1
fi

# Verify bus 1 is the iSMT adapter (where PCA9547 lives)
BUS1_NAME=$(cat /sys/bus/i2c/devices/i2c-1/name 2>/dev/null)
if ! echo "$BUS1_NAME" | grep -q "iSMT"; then
    echo "pre_pddf_init: ERROR - bus 1 is '$BUS1_NAME', expected iSMT"
    exit 1
fi

# Pre-create PCA9547 mux so child buses 2-9 exist before PDDF runs.
# When PDDF later tries to re-create this MUX via pddf_mux_module,
# i2c_new_client_device() returns ERR_PTR (device already exists).
# mux_parse() ignores this (create_mux_device() returns None) and
# proceeds to iterate channels — where buses now already exist.
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
        echo "pre_pddf_init: ERROR - MUX child bus 2 not created"
        exit 1
    fi
    echo "pre_pddf_init: MUX child buses created successfully"
fi

echo "pre_pddf_init: Bus state OK (i801=0, ismt=1, mux channels=2-9)"
exit 0
