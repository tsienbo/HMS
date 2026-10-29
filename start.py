import os
import sys
import subprocess
import webbrowser
import time
import threading

# 设置控制台颜色（让输出更好看，仅限支持 ANSI 的现代终端）
GREEN = "\033[92m"
YELLOW = "\033[93m"
RED = "\033[91m"
RESET = "\033[0m"

def print_banner():
    print("\n" + "="*45)
    print(f"  {GREEN}智慧医院预约挂号系统  Python + PostgreSQL{RESET}")
    print("="*45)
    print("  服务地址 : http://127.0.0.1:3000/")
    print("  停止服务 : 按 Ctrl+C 或直接关闭本窗口")
    print("\n  前置条件 :")
    print("    - PostgreSQL 服务已启动")
    print("    - 首次使用会自动建虚拟环境并装依赖")
    print("="*45 + "\n")

def open_browser_delayed():
    """延迟 2 秒后自动打开浏览器"""
    time.sleep(2)
    webbrowser.open("http://127.0.0.1:3000/")

def main():
    # 1. 确保工作目录是脚本所在的目录
    base_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(base_dir)
    
    print_banner()

    # 2. 根据操作系统确定虚拟环境里的 python 路径
    if sys.platform == "win32":
        venv_python = os.path.join(".venv", "Scripts", "python.exe")
    else:
        venv_python = os.path.join(".venv", "bin", "python")

    # 3. 首次运行：建虚拟环境并装依赖
    if not os.path.exists(venv_python):
        print(f"{YELLOW}  [准备] 没找到 .venv，正在创建虚拟环境...{RESET}")
        try:
            # 使用当前运行脚本的 Python 来创建虚拟环境
            subprocess.run([sys.executable, "-m", "venv", ".venv"], check=True)
        except subprocess.CalledProcessError:
            print(f"{RED}  [错误] 创建虚拟环境失败。请确认已安装 Python 3.9 以上。{RESET}")
            input("按回车键退出...")
            sys.exit(1)
            
        print(f"{YELLOW}  [准备] 安装依赖（需要联网，请稍候）...{RESET}")
        # 升级 pip (忽略输出)
        subprocess.run([venv_python, "-m", "pip", "install", "--upgrade", "pip"], 
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        # 安装依赖
        try:
            subprocess.run([venv_python, "-m", "pip", "install", "-r", "requirements.txt"], check=True)
        except subprocess.CalledProcessError:
            print(f"{RED}  [错误] 依赖安装失败，请检查网络或 requirements.txt。{RESET}")
            input("按回车键退出...")
            sys.exit(1)

    # 4. 首次运行：初始化数据库
    init_flag_file = ".db-initialized"
    if not os.path.exists(init_flag_file):
        print(f"{YELLOW}  [准备] 首次运行，初始化数据库...{RESET}")
        try:
            subprocess.run([venv_python, os.path.join("server", "app.py"), "--init"], check=True)
            # 创建标记文件
            with open(init_flag_file, "w") as f:
                f.write("done")
        except subprocess.CalledProcessError:
            print(f"{RED}  [错误] 数据库初始化失败，请确认 PostgreSQL 已启动，且账号密码正确。{RESET}")
            input("按回车键退出...")
            sys.exit(1)

    # 5. 启动服务并打开浏览器
    print(f"\n  [1/2] 启动服务，2 秒后自动打开浏览器...")
    # 开启后台线程打开浏览器
    threading.Thread(target=open_browser_delayed, daemon=True).start()

    print(f"  [2/2] 运行中，按 Ctrl+C 或关闭窗口停止\n")
    
    try:
        # 运行主服务
        subprocess.run([venv_python, os.path.join("server", "app.py")])
    except KeyboardInterrupt:
        print(f"\n{YELLOW}  服务已停止。{RESET}")
    except Exception as e:
        print(f"\n{RED}  服务运行出错: {e}{RESET}")
        input("按回车键退出...")

if __name__ == "__main__":
    main()