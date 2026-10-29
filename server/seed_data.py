# -*- coding: utf-8 -*-
"""写死的基础数据 —— 科室、医生、后台账号，以及排班的生成规则。

内容不多，摆在眼前比藏在配置文件里好读。
这些是「部署期常量」，不是业务数据：换一家医院才需要改。
"""

from datetime import date, timedelta

# ------------------------------------------------------------
# 科室
#
# 单院区部署，医院是部署期常量，所以没有 hospitals 表；
# 医院名称 / 等级 / 地址和科室图标都在前端 web/js/app.js 里。
# ------------------------------------------------------------
DEPARTMENTS = [
    {"id": "D01", "name": "内科", "description": "感冒发热、高血压、糖尿病等常见内科疾病", "location": "门诊楼 2 层东区"},
    {"id": "D02", "name": "外科", "description": "外伤处理、体表肿物、术后复查", "location": "门诊楼 3 层"},
    {"id": "D03", "name": "儿科", "description": "0-14 岁儿童常见病、生长发育咨询", "location": "门诊楼 1 层北侧（儿童医学中心）"},
    {"id": "D04", "name": "骨科", "description": "骨折、关节疼痛、颈腰椎疾病", "location": "门诊楼 3 层西区"},
    {"id": "D05", "name": "眼科", "description": "视力检查、结膜炎、白内障筛查", "location": "门诊楼 4 层"},
]

# 后台账号。这里写的是明文，灌库时派生成散列再存，明文不落库。
# 只有一个账号，所以没有 role 列。
USERS = [
    {"id": "U01", "username": "admin", "password": "admin123", "displayName": "张明"},
]

# 医生。挂号费由数据库约束锁死在「职称 → 价格」这一档上。
DOCTORS = [
    {"id": "DR01", "deptId": "D01", "name": "张建国", "title": "主任医师", "fee": 50},
    {"id": "DR02", "deptId": "D01", "name": "李慧敏", "title": "副主任医师", "fee": 30},
    {"id": "DR03", "deptId": "D01", "name": "王振宇", "title": "主治医师", "fee": 15},
    {"id": "DR04", "deptId": "D02", "name": "陈国强", "title": "主任医师", "fee": 50},
    {"id": "DR05", "deptId": "D02", "name": "刘文博", "title": "主治医师", "fee": 15},
    {"id": "DR06", "deptId": "D03", "name": "赵晓萍", "title": "副主任医师", "fee": 30},
    {"id": "DR07", "deptId": "D03", "name": "孙宁", "title": "主治医师", "fee": 15},
    {"id": "DR08", "deptId": "D04", "name": "周海涛", "title": "主任医师", "fee": 50},
    {"id": "DR09", "deptId": "D04", "name": "吴磊", "title": "主治医师", "fee": 15},
    {"id": "DR10", "deptId": "D05", "name": "郑晓岚", "title": "副主任医师", "fee": 30},
]

# 号源的最小单位就是「上午 / 下午」，不拆 30 分钟一格。
# 患者挂号只选半天，具体就诊顺序以到院取号后的现场叫号为准。
# start / end 是这一档的起止时间，写进 schedules.start_time / end_time，
# 由 ck_schedule_time_order 保证 end 晚于 start。
PERIODS = [
    {"key": "AM", "slot": "上午", "start": "08:00", "end": "12:00"},
    {"key": "PM", "slot": "下午", "start": "13:30", "end": "17:00"},
]

# 一个半天放多少号，按职称定档：职称越高号越少（越难挂）。
QUOTA_BY_TITLE = {
    "主任医师": 20,
    "副主任医师": 25,
    "主治医师": 30,
}

# 一次铺多少天的排班
SEED_DAYS = 14

# 登录后签发的令牌多久过期（小时）
SESSION_TTL_HOURS = 12

# Python 的 date.weekday() 是 0=周一，这里换成中文标签
WEEK_LABEL = ["周一", "周二", "周三", "周四", "周五", "周六", "周日"]


def weekday_label(d):
    """返回「周一」…「周日」。"""
    return WEEK_LABEL[d.weekday()]


def build_date_range(days, start=None):
    """从今天起，连续 days 天的 (date, 星期标签) 列表。"""
    start = start or date.today()
    return [(start + timedelta(days=i), weekday_label(start + timedelta(days=i)))
            for i in range(days)]


def build_schedules(days, start=None):
    """生成排班：未来 days 天 × 每位医生 × 上午/下午各一条。

    每条排班的已约数都是 0 —— 号是患者自己挂出来的。
    """
    out = []
    for d, wd in build_date_range(days, start):
        ds = d.isoformat()
        for doc in DOCTORS:
            for p in PERIODS:
                out.append({
                    "id": "SC_%s_%s_%s" % (doc["id"], ds, p["key"]),
                    "doctorId": doc["id"],
                    "deptId": doc["deptId"],
                    "date": d,
                    "weekday": wd,
                    "timeSlot": p["slot"],
                    "startTime": p["start"],
                    "endTime": p["end"],
                    "room": "诊室 %02d" % int(doc["id"][2:]),
                    "maxQuota": QUOTA_BY_TITLE[doc["title"]],
                })
    return out
