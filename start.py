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

    # 4. 检查数据库：每次启动都跑一遍 --init
    #    它是幂等的 —— 新机器上建库建表灌数据；已有库只补缺失对象和未来 14 天的排班，
    #    不动已有挂号（表不完整但有业务数据时会停下来报错，不会自动重建）。
    #    以前靠 .db-initialized 标记文件判断「是否初始化过」，标记文件跟着仓库走，
    #    新机器上会因为有这个文件而跳过建库，然后连不上库。
    print(f"{YELLOW}  [准备] 检查数据库（首次会建库，之后只补排班）...{RESET}")
    try:
        subprocess.run([venv_python, os.path.join("server", "app.py"), "--init"], check=True)
    except subprocess.CalledProcessError:
        print(f"{RED}  [错误] 数据库检查失败，请看上面的提示（PostgreSQL 是否已启动、账号密码是否正确）。{RESET}")
        input("按回车键退出...")
        sys.exit(1)

    # 5. 后台 worker：就诊提醒、候补 2 小时过期顺延、发邮件，每分钟跑一次。
    #    和 Web 服务一起启动、一起停止；不开它，这些只有在后台点「通知扫描」时才会发生。
    worker = subprocess.Popen([venv_python, os.path.join("server", "app.py"), "--worker"])

    # 6. 启动服务并打开浏览器
    print(f"\n  [1/2] 启动服务，2 秒后自动打开浏览器...")
    threading.Thread(target=open_browser_delayed, daemon=True).start()

    print(f"  [2/2] 运行中，按 Ctrl+C 或关闭窗口停止\n")

    try:
        subprocess.run([venv_python, os.path.join("server", "app.py")])
    except KeyboardInterrupt:
        print(f"\n{YELLOW}  服务已停止。{RESET}")
    except Exception as e:
        print(f"\n{RED}  服务运行出错: {e}{RESET}")
        input("按回车键退出...")
    finally:
        worker.terminate()
        try:
            worker.wait(timeout=5)
        except subprocess.TimeoutExpired:
            worker.kill()

if __name__ == "__main__":
    main()