#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
仅下载已触发构建产出的 release APK（不 bump / 不 push）。
用于：CI 已触发但自动下载进程中断的场景，补跑下载环节。
"""
import argparse
import base64
import json
import os
import re
import sys
import time
import urllib.request
import urllib.error
import urllib.parse
import zipfile

API = "https://api.github.com"


class NoAuthRedirect(urllib.request.HTTPRedirectHandler):
    """跨域重定向（GitHub API -> Azure 存储 SAS URL）时不要转发 Authorization 头，否则 403。"""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        new_req = super().redirect_request(req, fp, code, msg, headers, newurl)
        if new_req is not None:
            src_host = urllib.parse.urlparse(req.full_url).netloc
            dst_host = urllib.parse.urlparse(newurl).netloc
            if dst_host != src_host:
                new_req.remove_header("Authorization")
        return new_req


def gh_get(path, token):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "token " + token)
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, json.loads(r.read().decode() or "{}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run-id", required=True)
    ap.add_argument("--head-sha", required=True)
    ap.add_argument("--out-dir", default=r"D:/sleep_app/release_apk")
    ap.add_argument("--owner", default="CCB-ccb-ccc")
    ap.add_argument("--repo", default="sleep-video-player")
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("缺少环境变量 GITHUB_TOKEN")

    # 1. 从已提交树读取版本号
    try:
        _, data = gh_get(
            f"/repos/{args.owner}/{args.repo}/contents/pubspec.yaml?ref={args.head_sha}",
            token,
        )
        content = base64.b64decode(data["content"]).decode("utf-8")
        m = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)", content, re.M)
        new_ver = m.group(1) + "." + m.group(2) + "." + m.group(3) + "+" + m.group(4) if m else "unknown"
        print(f"[version] 提交树中的版本: {new_ver}")
    except Exception as e:
        print("[warn] 读取版本号失败，使用 unknown:", e)
        new_ver = "unknown"

    # 2. 轮询 CI
    deadline = time.time() + 40 * 60
    final = None
    while time.time() < deadline:
        try:
            _, data = gh_get(
                f"/repos/{args.owner}/{args.repo}/actions/runs/{args.run_id}", token
            )
        except Exception as e:
            print("[warn] 查询状态失败，重试:", e)
            time.sleep(30)
            continue
        status = data.get("status")
        concl = data.get("conclusion")
        print(f"[ci] status={status} conclusion={concl}")
        if status == "completed":
            final = concl
            break
        time.sleep(45)
    if final != "success":
        raise SystemExit(f"CI 构建未成功（结论: {final}），请到 Actions 页面查看日志")

    # 3. 下载构件
    _, data = gh_get(
        f"/repos/{args.owner}/{args.repo}/actions/runs/{args.run_id}/artifacts", token
    )
    art = None
    for a in data.get("artifacts", []):
        if not a.get("expired"):
            art = a
            break
    if not art:
        raise SystemExit("未找到可用的构建构件")
    print(f"[artifact] {art['name']} (id={art['id']})")

    os.makedirs(args.out_dir, exist_ok=True)
    zip_path = os.path.join(args.out_dir, "_release_artifact.zip")
    url = f"{API}/repos/{args.owner}/{args.repo}/actions/artifacts/{art['id']}/zip"
    req = urllib.request.Request(url)
    req.add_header("Authorization", "token " + token)
    req.add_header("Accept", "application/vnd.github+json")
    print("[download] 开始下载构件 zip ...")
    opener = urllib.request.build_opener(NoAuthRedirect())
    with opener.open(req, timeout=600) as r, open(zip_path, "wb") as f:
        while True:
            buf = r.read(1024 * 1024)
            if not buf:
                break
            f.write(buf)
    print(f"[download] zip 已保存: {zip_path}")

    # 4. 解压出 app-release.apk
    with zipfile.ZipFile(zip_path) as z:
        apk_entries = [n for n in z.namelist() if n.endswith("app-release.apk")]
        if not apk_entries:
            raise SystemExit("构件中未找到 app-release.apk")
        apk_name = apk_entries[0]
        apk_bytes = z.read(apk_name)
    latest_path = os.path.join(args.out_dir, "app-release.apk")
    versioned_path = os.path.join(args.out_dir, f"app-release-{new_ver}.apk")
    with open(latest_path, "wb") as f:
        f.write(apk_bytes)
    with open(versioned_path, "wb") as f:
        f.write(apk_bytes)
    # 沙箱环境回收站不可用，删除可能被拦截；非致命，仅提示
    try:
        os.remove(zip_path)
    except Exception as e:
        print(f"[warn] 无法删除临时 zip（沙箱限制，可忽略）: {e}")

    size_mb = len(apk_bytes) / 1024 / 1024
    print("[done] 发布完成：")
    print(json.dumps({
        "version": new_ver,
        "apk_latest": latest_path,
        "apk_versioned": versioned_path,
        "size_mb": round(size_mb, 1),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
