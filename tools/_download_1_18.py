import urllib.request, base64, os, time, sys

TK = os.environ.get("TK") or os.environ.get("GITHUB_TOKEN")
if not TK:
    print("缺少 TK/GITHUB_TOKEN"); sys.exit(1)

URL = "https://github.com/CCB-ccb-ccc/sleep-video-player/releases/download/v1.18.0/app-release.apk"
OUT = r"D:/sleep_app/release_apk/app-release-1.18.0+20.apk"
os.makedirs(os.path.dirname(OUT), exist_ok=True)

def auth(url, method="HEAD"):
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", "Basic " + base64.b64encode((TK + ":").encode()).decode())
    return req

deadline = time.time() + 25 * 60
while time.time() < deadline:
    try:
        with urllib.request.urlopen(auth(URL, "HEAD"), timeout=30) as r:
            if r.status == 200:
                print("[ok] asset 就绪, 开始下载 ...")
                with urllib.request.urlopen(auth(URL, "GET"), timeout=600) as resp, open(OUT, "wb") as f:
                    total = 0
                    while True:
                        buf = resp.read(1024 * 1024)
                        if not buf:
                            break
                        f.write(buf)
                        total += len(buf)
                print(f"[done] 已下载 {total/1024/1024:.1f} MB -> {OUT}")
                sys.exit(0)
            else:
                print(f"[wait] 状态码 {r.status}")
    except Exception as e:
        print(f"[wait] {repr(e)}")
    time.sleep(30)

print("[timeout] 等待 Release 资产超时（CI 可能失败）")
sys.exit(2)
