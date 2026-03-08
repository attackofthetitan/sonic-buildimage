from sonic_platform_base.sonic_thermal_control.thermal_info_base import ThermalPolicyInfoBase
from sonic_platform_base.sonic_thermal_control.thermal_json_object import thermal_json_object
from sonic_py_common import logger

sonic_logger = logger.Logger('thermal_infos')


@thermal_json_object('fan_info')
class FanInfo(ThermalPolicyInfoBase):
    INFO_NAME = 'fan_info'

    def __init__(self):
        self._absence_fans = set()
        self._presence_fans = set()
        self._absence_fantrays = set()
        self._presence_fantrays = set()
        self._all_fans = set()

    def collect(self, chassis):
        try:
            for fantray in chassis.get_all_fan_drawers():
                if fantray.get_presence():
                    self._presence_fantrays.add(fantray)
                    self._absence_fantrays.discard(fantray)
                else:
                    self._absence_fantrays.add(fantray)
                    self._presence_fantrays.discard(fantray)

                for fan in fantray.get_all_fans():
                    self._all_fans.add(fan)
                    if fan.get_presence():
                        self._presence_fans.add(fan)
                        self._absence_fans.discard(fan)
                    else:
                        self._absence_fans.add(fan)
                        self._presence_fans.discard(fan)
        except Exception as e:
            sonic_logger.log_warning("FanInfo collect error: {}".format(e))

    def get_absence_fantrays(self):
        return self._absence_fantrays

    def get_presence_fantrays(self):
        return self._presence_fantrays

    def get_all_fans(self):
        return self._all_fans


@thermal_json_object('psu_info')
class PsuInfo(ThermalPolicyInfoBase):
    INFO_NAME = 'psu_info'

    def __init__(self):
        self._absence_psus = set()
        self._presence_psus = set()

    def collect(self, chassis):
        try:
            for psu in chassis.get_all_psus():
                if psu.get_presence():
                    self._presence_psus.add(psu)
                    self._absence_psus.discard(psu)
                else:
                    self._absence_psus.add(psu)
                    self._presence_psus.discard(psu)
        except Exception as e:
            sonic_logger.log_warning("PsuInfo collect error: {}".format(e))

    def get_absence_psus(self):
        return self._absence_psus

    def get_presence_psus(self):
        return self._presence_psus


@thermal_json_object('thermal_info')
class ThermalInfo(ThermalPolicyInfoBase):
    INFO_NAME = 'thermal_info'

    def __init__(self):
        self._high_warning_thermals = set()
        self._high_shutdown_thermals = set()

    def collect(self, chassis):
        try:
            for thermal in chassis.get_all_thermals():
                name = thermal.get_name()
                temp = thermal.get_temperature()
                if temp is None or temp == 'N/A':
                    continue

                high_threshold = thermal.get_high_threshold()
                high_crit = thermal.get_high_critical_threshold()

                if high_threshold is not None and high_threshold != 'N/A':
                    if temp > high_threshold:
                        if thermal not in self._high_warning_thermals:
                            self._high_warning_thermals.add(thermal)
                            sonic_logger.log_warning("Thermal {} temp {}, over high threshold {}".format(
                                name, temp, high_threshold))
                    elif temp < (high_threshold - 3):
                        if thermal in self._high_warning_thermals:
                            self._high_warning_thermals.discard(thermal)
                            sonic_logger.log_notice("Thermal {} restored from high threshold warning".format(name))

                if high_crit is not None and high_crit != 'N/A':
                    if temp > high_crit:
                        if thermal not in self._high_shutdown_thermals:
                            self._high_shutdown_thermals.add(thermal)
                            sonic_logger.log_warning("Thermal {} temp {}, CRITICAL over {}".format(
                                name, temp, high_crit))
                    elif temp < (high_crit - 3):
                        self._high_shutdown_thermals.discard(thermal)
        except Exception as e:
            sonic_logger.log_warning("ThermalInfo collect error: {}".format(e))

    def is_any_over_high_threshold(self):
        return len(self._high_warning_thermals) > 0

    def is_any_over_high_critical_threshold(self):
        return len(self._high_shutdown_thermals) > 0


@thermal_json_object('chassis_info')
class ChassisInfo(ThermalPolicyInfoBase):
    INFO_NAME = 'chassis_info'

    def __init__(self):
        self._chassis = None

    def collect(self, chassis):
        self._chassis = chassis

    def get_chassis(self):
        return self._chassis
