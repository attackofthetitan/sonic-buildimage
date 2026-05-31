from sonic_platform_base.sonic_thermal_control.thermal_action_base import ThermalPolicyActionBase
from sonic_platform_base.sonic_thermal_control.thermal_json_object import thermal_json_object
from sonic_py_common import logger

sonic_logger = logger.Logger('thermal_actions')


class SetFanSpeedAction(ThermalPolicyActionBase):
    JSON_FIELD_SPEED = 'speed'

    def __init__(self):
        self.speed = 50

    def load_from_json(self, json_obj):
        if self.JSON_FIELD_SPEED in json_obj:
            speed = float(json_obj[self.JSON_FIELD_SPEED])
            if speed < 0 or speed > 100:
                raise ValueError('SetFanSpeedAction invalid speed {}'.format(speed))
            self.speed = speed
        else:
            raise ValueError('SetFanSpeedAction missing speed field')

    @classmethod
    def set_all_fan_speed(cls, thermal_info_dict, speed):
        from .thermal_infos import FanInfo, PsuInfo
        speed_int = int(speed)
        if FanInfo.INFO_NAME in thermal_info_dict and isinstance(thermal_info_dict[FanInfo.INFO_NAME], FanInfo):
            fan_info = thermal_info_dict[FanInfo.INFO_NAME]
            for fan in fan_info.get_all_fans():
                fan.set_speed(speed_int)
        # Also set PSU fan speed to match, as in the original fancontrol script
        if PsuInfo.INFO_NAME in thermal_info_dict and isinstance(thermal_info_dict[PsuInfo.INFO_NAME], PsuInfo):
            psu_info = thermal_info_dict[PsuInfo.INFO_NAME]
            for psu in psu_info.get_presence_psus():
                for fan in psu.get_all_fans():
                    try:
                        fan.set_speed(speed_int)
                    except Exception as e:
                        sonic_logger.log_warning("Failed to set PSU fan speed: {}".format(e))


@thermal_json_object('fan.all.set_speed')
class SetAllFanSpeedAction(SetFanSpeedAction):
    def execute(self, thermal_info_dict):
        sonic_logger.log_info("Setting all fan speed to {}%".format(self.speed))
        SetAllFanSpeedAction.set_all_fan_speed(thermal_info_dict, self.speed)


@thermal_json_object('switch.shutdown')
class SwitchPolicyAction(ThermalPolicyActionBase):
    def execute(self, thermal_info_dict):
        sonic_logger.log_warning("Critical temperature detected, shutting down system")
        import subprocess
        subprocess.call(['shutdown', '-h', 'now'])
