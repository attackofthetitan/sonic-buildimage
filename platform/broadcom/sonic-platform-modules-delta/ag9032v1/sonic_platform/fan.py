#!/usr/bin/env python

import smbus

try:
    from sonic_platform_pddf_base.pddf_fan import PddfFan
except ImportError as e:
    raise ImportError(str(e) + "- required module not found")


class Fan(PddfFan):
    """PDDF Platform-Specific Fan class"""

    # Fan tray EEPROM bus/address mapping (1-indexed by tray number)
    FAN_TRAY_EEPROM = {
        1: (31, 0x51),
        2: (32, 0x52),
        3: (33, 0x53),
        4: (34, 0x54),
        5: (35, 0x55),
    }

    def __init__(self, tray_idx, fan_idx=0, pddf_data=None, pddf_plugin_data=None, is_psu_fan=False, psu_index=0):
        # idx is 0-based
        PddfFan.__init__(self, tray_idx, fan_idx, pddf_data, pddf_plugin_data, is_psu_fan, psu_index)

    def get_presence(self):
        """
        Retrieves the presence of the fan tray by probing the fan EEPROM.
        Each fan tray has an EEPROM that is only accessible when the tray is inserted.
        """
        if self.is_psu_fan:
            return True

        tray = self.fantray_index  # 1-based
        if tray not in self.FAN_TRAY_EEPROM:
            return False

        bus_num, addr = self.FAN_TRAY_EEPROM[tray]
        try:
            bus = smbus.SMBus(bus_num)
            bus.read_byte_data(addr, 0)
            bus.close()
            return True
        except Exception:
            return False

    def get_direction(self):
        """
        Retrieves the direction of fan.
        AG9032V1 fans are all front-to-back (exhaust).
        """
        return self.FAN_DIRECTION_EXHAUST
