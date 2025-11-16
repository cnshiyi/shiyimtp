#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import asyncio
import pymysql
import boto3
import asyncssh
import redis
from datetime import datetime

from aiogram import Bot, Dispatcher
from aiogram.types import Message, InlineKeyboardMarkup, InlineKeyboardButton
from aiogram import F
from aiogram.client.default import DefaultBotProperties

from config import (
    BOT_TOKEN,
    DB_CONFIG,
    SNAP_TABLES,
    ACCOUNT_MAP,
    AWS_ACCOUNTS,
    SSH_KEYS,
    WHITE_LIST,
    REDIS_CONFIG
)

# Redis
rds = redis.Redis(
    host=REDIS_CONFIG["host"],
    port=REDIS_CONFIG["port"],
    password=REDIS_CONFIG["password"],
    db=REDIS_CONFIG["db"],
    decode_responses=True
)

REGION_CODE_MAP = {
    "新加坡": "ap-southeast-1",
    "东京": "ap-northeast-1",
    "首尔": "ap-northeast-2",
    "孟买": "ap-south-1",
    "悉尼": "ap-southeast-2",
    "法兰克福": "eu-central-1",
    "巴黎": "eu-west-3",
    "伦敦": "eu-west-2",
    "爱尔兰": "eu-west-1",
    "蒙特利尔": "ca-central-1",
    "俄勒冈州": "us-west-2",
    "俄亥俄州": "us-east-2",
    "弗吉尼亚州": "us-east-1",
    "斯德哥尔摩": "eu-north-1",
}


def is_allowed(uid: int):
    return uid in WHITE_LIST


def log_success(msg): print(f"[SUCCESS {datetime.now()}] {msg}")


# ------------------------- 查询系统（AWS API） -------------------------
def get_system_from_aws(instance_name, region, account_id):
    try:
        region_code = REGION_CODE_MAP.get(region, region)
        acc = AWS_ACCOUNTS[account_id]

        client = boto3.client(
            "lightsail",
            aws_access_key_id=acc["access_key"],
            aws_secret_access_key=acc["secret_key"],
            region_name=region_code,
        )

        resp = client.get_instance(instanceName=instance_name)
        blueprint = resp["instance"]["blueprintId"].lower()

        if "ubuntu" in blueprint:
            return "Ubuntu Linux"
        if "debian" in blueprint:
            return "Debian Linux"
        if "centos" in blueprint:
            return "CentOS Linux"
        if "rocky" in blueprint:
            return "Rocky Linux"
        if "alma" in blueprint:
            return "AlmaLinux"
        if "amazon" in blueprint:
            return "Amazon Linux"
        if "windows" in blueprint:
            return "Windows Server"

        return f"未知系统 ({blueprint})"

    except Exception as e:
        return f"❌ 查询系统信息失败：{e}"


# ------------------------- AWS 开放端口（替代 SSH） -------------------------
def aws_open_port(instance_name, region, account_id, port):
    try:
        region_code = REGION_CODE_MAP.get(region, region)
        acc = AWS_ACCOUNTS[account_id]

        client = boto3.client(
            "lightsail",
            aws_access_key_id=acc["access_key"],
            aws_secret_access_key=acc["secret_key"],
            region_name=region_code
        )

        client.open_instance_public_ports(
            instanceName=instance_name,
            portInfo={
                "fromPort": int(port),
                "toPort": int(port),
                "protocol": "tcp"
            }
        )

        return f"🟢 端口 {port} 已通过 AWS API 成功放行（无需 SSH）"

    except Exception as e:
        return f"❌ AWS API 放行端口失败：{e}"


# ------------------------- SSH 检查端口是否监听（保留） -------------------------
async def ssh_check_port(ip, account_id, region, port):
    region_code = REGION_CODE_MAP.get(region, region)
    priv_key = SSH_KEYS.get(account_id, {}).get(region_code)
    if not priv_key:
        return "❌ 无 SSH 私钥"

    cmd = f"""
sudo -i;
sudo ss -tulnp | grep :{port} -w 2>/dev/null;
"""

    for user in ["root", "ubuntu", "admin"]:
        try:
            async with asyncssh.connect(ip, username=user, client_keys=[priv_key], known_hosts=None) as conn:
                result = await conn.run(cmd, check=False)
                return result.stdout or "未监听"
        except:
            continue

    return "❌ SSH 登录失败，无法检查端口"


# ------------------------- 数据库查询 -------------------------
def search_instance(keyword):
    conn = pymysql.connect(**DB_CONFIG)
    results = {"snapshot": []}

    with conn.cursor(pymysql.cursors.DictCursor) as cur:
        cur.execute("SELECT * FROM data WHERE ip=%s OR instance_name=%s", (keyword, keyword))
        results["data"] = cur.fetchall()

    conn.close()
    return results


# ------------------------- 回复格式 -------------------------
def format_response(keyword, d):
    sys_info = get_system_from_aws(d["instance_name"], d["region"], d["account_id"])

    return (
        f"<b>🔍 查询：</b><code>{keyword}</code>\n\n"
        f"<b>实例名：</b><code>{d['instance_name']}</code>\n"
        f"<b>IP：</b><code>{d['ip']}</code>\n"
        f"<b>区域：</b><code>{d['region']}</code>\n"
        f"<b>系统：</b><code>{sys_info}</code>\n"
        f"<b>到期：</b><code>{d['expiration_date']}</code>\n"
        f"<b>账号：</b><code>{ACCOUNT_MAP.get(d['account_id'], d['account_id'])}</code>\n"
    )


# ------------------------- Aiogram -------------------------
bot = Bot(token=BOT_TOKEN, default=DefaultBotProperties(parse_mode="HTML"))
dp = Dispatcher()


# ========================= 文本消息入口 =========================
@dp.message(F.text)
async def handle_msg(message: Message):

    if not is_allowed(message.from_user.id):
        return await message.answer("❌ 无权限")

    uid = message.from_user.id
    text = message.text.strip()

    # ───── 用户输入端口（等待中）─────
    if rds.get(f"wait_port:{uid}"):
        instance_name, ip, acc, region = rds.get(f"wait_port:{uid}").split("|")
        rds.delete(f"wait_port:{uid}")

        port = int(text)

        # AWS API 开放端口
        result_api = aws_open_port(instance_name, region, acc, port)

        # SSH 查询端口是否监听（可选）
        result_ssh = await ssh_check_port(ip, acc, region, port)

        return await message.answer(
            f"🟢 AWS 放行结果：\n<code>{result_api}</code>\n\n"
            f"📡 端口监听情况（SSH）：\n<code>{result_ssh}</code>"
        )

    # ───── 正常查询实例信息 ─────
    result = search_instance(text)
    if not result["data"]:
        return await message.answer("❌ 未找到记录")

    d = result["data"][0]

    # 直接在格式化结果中返回系统信息（无按钮）
    msg = format_response(text, d)

    # 按钮
    kb = InlineKeyboardMarkup(
        inline_keyboard=[
            [
                InlineKeyboardButton(
                    text="🔧 放行端口（AWS API）",
                    callback_data=f"askPort:{d['instance_name']}:{d['ip']}:{d['account_id']}:{d['region']}"
                )
            ],
            [
                InlineKeyboardButton(
                    text="💻 SSH 执行 MTProxy",
                    callback_data=f"ssh:{d['ip']}:{d['account_id']}:{d['region']}"
                )
            ],
        ]
    )

    return await message.answer(msg, reply_markup=kb)


# ========================= 点击按钮：准备输入端口 =========================
@dp.callback_query(F.data.startswith("askPort:"))
async def cb_ask_port(cb):
    _, name, ip, acc, region = cb.data.split(":")
    uid = cb.from_user.id

    # 记录状态
    rds.set(f"wait_port:{uid}", f"{name}|{ip}|{acc}|{region}")

    await cb.message.answer("🔢 请输入要放行的端口号，例如：443")


# ========================= SSH 执行 MTProxy =========================
@dp.callback_query(F.data.startswith("ssh:"))
async def cb_ssh(cb):
    _, ip, acc, region = cb.data.split(":")

    await cb.message.answer("💻 正在执行 MTProxy 启动脚本...")

    region_code = REGION_CODE_MAP.get(region, region)
    priv_key = SSH_KEYS.get(acc, {}).get(region_code)

    for user in ["root", "ubuntu", "admin"]:
        try:
            async with asyncssh.connect(ip, username=user, client_keys=[priv_key], known_hosts=None) as conn:
                result = await conn.run("sudo -i; cd /home/mtproxy; bash mtproxy.sh start", check=False)
                return await cb.message.answer(f"<code>{result.stdout}</code>")
        except:
            continue

    await cb.message.answer("❌ SSH 登录失败")


# ========================= 主程序 =========================
async def main():
    log_success("🤖 AWS 搜索 + 系统识别 + AWS 放行端口 + SSH + 自定义端口机器人已启动")
    await dp.start_polling(bot)


if __name__ == "__main__":
    asyncio.run(main())
