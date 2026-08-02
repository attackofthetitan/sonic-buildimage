#!/usr/bin/env python

try:
    from sonic_platform_pddf_base.pddf_fan import PddfFan
except ImportError as e:
    raise ImportError(str(e) + "- required module not found")


class Fan(PddfFan):

    def __init__(self, tray_idx, fan_idx=0, pddf_data=None, pddf_plugin_data=None, is_psu_fan=False, psu_index=0):
        PddfFan.__init__(self, tray_idx, fan_idx, pddf_data, pddf_plugin_data, is_psu_fan, psu_index)

    def get_presence(self):
        if not self.is_psu_fan:
            return PddfFan.get_presence(self)

        device = "PSU{}".format(self.fans_psu_index)
        output = self.pddf_obj.get_attr_name_output(device, "psu_present")
        if not output:
            return False

        mode = output.get("mode")
        status = str(output.get("status", "")).rstrip()
        try:
            valmap = self.plugin_data["PSU"]["psu_present"][mode]["valmap"]
            return valmap.get(status, False)
        except (KeyError, TypeError, AttributeError):
            return False

    def get_status(self):
        if self.is_psu_fan and not self.get_presence():
            return False
        return PddfFan.get_status(self)

    def get_direction(self):
        """
        Retrieves the direction of fan.
        AG9032V1 fans are all front-to-back (exhaust).
        """
        return self.FAN_DIRECTION_EXHAUST
