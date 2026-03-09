from sonic_platform_base.sonic_thermal_control.thermal_info_base import ThermalPolicyInfoBase
from sonic_platform_base.sonic_thermal_control.thermal_json_object import thermal_json_object
from sonic_py_common import logger

sonic_logger = logger.Logger('thermal_infos')

# Per-sensor thermal level thresholds from original Delta fancontrol.
# Each sensor has LOWER[] and UPPER[] arrays indexed 0-5.
# Index 0 = level 6 (coolest, 30%), index 5 = level 1 (hottest, 100%).
SENSOR_THRESHOLDS = {
    'CPU below side thermal sensor': {
        'lower': [0, 36, 41, 46, 55, 55],
        'upper': [39, 44, 49, 54, 150, 150],
    },
    'Wind thermal sensor': {
        'lower': [0, 65, 69, 73, 82, 82],
        'upper': [63, 71, 75, 79, 150, 150],
    },
    'MAC up side thermal sensor': {
        'lower': [0, 55, 59, 63, 71, 71],
        'upper': [53, 61, 65, 69, 150, 150],
    },
    'MAC down side thermal sensor': {
        'lower': [0, 55, 59, 63, 71, 71],
        'upper': [53, 61, 65, 69, 150, 150],
    },
    'Surroundings thermal sensor': {
        'lower': [0, 50, 54, 58, 65, 65],
        'upper': [45, 56, 60, 64, 150, 150],
    },
}

# just in case
DEFAULT_THRESHOLDS = {
    'lower': [0, 36, 41, 46, 55, 55],
    'upper': [39, 44, 49, 54, 150, 150],
}


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
        self._sensor_levels = {}  # sensor_name -> current level (1-6)
        self._min_level = 6
        self._high_shutdown_thermals = set()

    def _get_sensor_level(self, name, temp):
        # find range of temperature and return corresponding level
        thresholds = SENSOR_THRESHOLDS.get(name, DEFAULT_THRESHOLDS)
        lower = thresholds['lower']
        upper = thresholds['upper']

        # Start with previous level if available to avoid unnecessary fan speed changes.
        prev_level = self._sensor_levels.get(name, 4)
        # Convert level to index
        idx = 6 - prev_level

        while True:
            if lower[idx] <= temp <= upper[idx]:
                break
            elif temp > upper[idx]:
                if idx < 5:
                    idx += 1
                else:
                    break
            elif temp < lower[idx]:
                if idx > 0:
                    idx -= 1
                else:
                    break
            else:
                break

        return 6 - idx

    def collect(self, chassis):
        try:
            for thermal in chassis.get_all_thermals():
                name = thermal.get_name()
                temp = thermal.get_temperature()
                if temp is None or temp == 'N/A':
                    continue

                temp_c = float(temp)

                # Only sensors with defined thresholds participate
                if name in SENSOR_THRESHOLDS:
                    level = self._get_sensor_level(name, temp_c)
                    old_level = self._sensor_levels.get(name, 4)
                    if level != old_level:
                        sonic_logger.log_info("Thermal {} temp {:.1f}C level {} -> {}".format(
                            name, temp_c, old_level, level))
                    self._sensor_levels[name] = level

                # Check critical threshold for emergency shutdown
                high_crit = thermal.get_high_critical_threshold()
                if high_crit is not None and high_crit != 'N/A':
                    if temp_c > float(high_crit):
                        if thermal not in self._high_shutdown_thermals:
                            self._high_shutdown_thermals.add(thermal)
                            sonic_logger.log_warning("Thermal {} temp {:.1f}C CRITICAL over {}".format(
                                name, temp_c, high_crit))
                    elif temp_c < (float(high_crit) - 3):
                        self._high_shutdown_thermals.discard(thermal)
        except Exception as e:
            sonic_logger.log_warning("ThermalInfo collect error: {}".format(e))

        # Minimum level across all sensors 
        if self._sensor_levels:
            self._min_level = min(self._sensor_levels.values())
        else:
            self._min_level = 4

    def get_min_thermal_level(self):
        return self._min_level

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
