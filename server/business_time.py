"""医院业务时间，应用日期、提醒时间窗和数据库会话统一使用北京时间。"""
from datetime import datetime
from zoneinfo import ZoneInfo

BUSINESS_ZONE = ZoneInfo("Asia/Shanghai")


def now():
    return datetime.now(BUSINESS_ZONE)


def today():
    return now().date()
