from sonic_platform_base.sonic_thermal_control.thermal_condition_base import ThermalPolicyConditionBase
from sonic_platform_base.sonic_thermal_control.thermal_json_object import thermal_json_object


class FanCondition(ThermalPolicyConditionBase):
    def get_fan_info(self, thermal_info_dict):
        from .thermal_infos import FanInfo
        if FanInfo.INFO_NAME in thermal_info_dict and isinstance(thermal_info_dict[FanInfo.INFO_NAME], FanInfo):
            return thermal_info_dict[FanInfo.INFO_NAME]
        return None


@thermal_json_object('fantray.any.absence')
class AnyFantrayAbsenceCondition(FanCondition):
    def is_match(self, thermal_info_dict):
        fan_info = self.get_fan_info(thermal_info_dict)
        return len(fan_info.get_absence_fantrays()) > 0 if fan_info else False


@thermal_json_object('fantray.all.presence')
class AllFantrayPresenceCondition(FanCondition):
    def is_match(self, thermal_info_dict):
        fan_info = self.get_fan_info(thermal_info_dict)
        return len(fan_info.get_absence_fantrays()) == 0 if fan_info else True


class ThermalLevelCondition(ThermalPolicyConditionBase):
    def get_thermal_info(self, thermal_info_dict):
        from .thermal_infos import ThermalInfo
        if ThermalInfo.INFO_NAME in thermal_info_dict and isinstance(thermal_info_dict[ThermalInfo.INFO_NAME], ThermalInfo):
            return thermal_info_dict[ThermalInfo.INFO_NAME]
        return None


@thermal_json_object('thermal.over.high_critical_threshold')
class ThermalOverHighCriticalCondition(ThermalLevelCondition):
    def is_match(self, thermal_info_dict):
        thermal_info = self.get_thermal_info(thermal_info_dict)
        return thermal_info.is_any_over_high_critical_threshold() if thermal_info else False


@thermal_json_object('thermal.level.at_or_below.2')
class ThermalLevelAtOrBelow2(ThermalLevelCondition):
    # any sensor at level 1 or 2 -> 100% fans
    def is_match(self, thermal_info_dict):
        thermal_info = self.get_thermal_info(thermal_info_dict)
        return thermal_info.get_min_thermal_level() <= 2 if thermal_info else False


@thermal_json_object('thermal.level.at.3')
class ThermalLevelAt3(ThermalLevelCondition):
    # minimum sensor level is exactly 3 -> 80% fans
    def is_match(self, thermal_info_dict):
        thermal_info = self.get_thermal_info(thermal_info_dict)
        return thermal_info.get_min_thermal_level() == 3 if thermal_info else False


@thermal_json_object('thermal.level.at.4')
class ThermalLevelAt4(ThermalLevelCondition):
    # minimum sensor level is exactly 4 -> 60% fans
    def is_match(self, thermal_info_dict):
        thermal_info = self.get_thermal_info(thermal_info_dict)
        return thermal_info.get_min_thermal_level() == 4 if thermal_info else False


@thermal_json_object('thermal.level.at.5')
class ThermalLevelAt5(ThermalLevelCondition):
    # minimum sensor level is exactly 5 -> 40% fans
    def is_match(self, thermal_info_dict):
        thermal_info = self.get_thermal_info(thermal_info_dict)
        return thermal_info.get_min_thermal_level() == 5 if thermal_info else False


@thermal_json_object('thermal.level.at_or_above.6')
class ThermalLevelAtOrAbove6(ThermalLevelCondition):
    # all sensors at level 6 -> 30% fans
    def is_match(self, thermal_info_dict):
        thermal_info = self.get_thermal_info(thermal_info_dict)
        return thermal_info.get_min_thermal_level() >= 6 if thermal_info else True
