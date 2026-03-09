#!/usr/bin/env python

try:
    from sonic_platform_pddf_base.pddf_fan import PddfFan
except ImportError as e:
    raise ImportError(str(e) + "- required module not found")


class Fan(PddfFan):

    def __init__(self, tray_idx, fan_idx=0, pddf_data=None, pddf_plugin_data=None, is_psu_fan=False, psu_index=0):
        PddfFan.__init__(self, tray_idx, fan_idx, pddf_data, pddf_plugin_data, is_psu_fan, psu_index)

    def get_direction(self):
        """
        Retrieves the direction of fan.
        AG9032V1 fans are all front-to-back (exhaust).
        """
        return self.FAN_DIRECTION_EXHAUST
