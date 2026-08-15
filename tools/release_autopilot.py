#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
本地「发布自动流程」脚本（固定流程，可重复使用）
================================================
职责（一条命令完成一次新版发布）：
  1. 版本号自增：修改 pubspec.yaml 的 version: X.Y.Z+CODE
       --bump patch  -> 1.0.0+1 -> 1.0.1+2  (默认，versionName 末位 +1，versionCode 必 +1)
       --bump minor  -> 1.0.0+1 -> 1.1.0+2
       --bump major  -> 1.0.0+1 -> 2.0.0+2
  2. 提交并推送到 master，触发 GitHub Actions 云端构建 release APK
  3. 轮询 CI 运行状态，直到 completed
  4. 构建成功后，自动下载 app-release.apk 到本地文件夹（默认 D:/sleep_app/release_apk）
     - 同时保存 app-release.apk（最新）与 app-release-<版本>.apk（带版本号备份）

前置条件：
  - 环境变量 GITHUB_TOKEN（有 repo + workflow 权限）
  - 当前目录是 Flutter 工程根（含 pubspec.yaml、.git）
  - 远程 origin 指向 github.com 上的仓库（自动解析 owner/repo）
  - CI 工作流已配置：push 到 master 即构建并上传 app-release-apk 构件

用法：
  GITHUB_TOKEN=xxx python tools/release_autopilot.py --bump patch
  python tools/release_autopilot.py --bump minor --out-dir D:/sleep_app/release_apk
"""
import argparse
import json
import os
import re
import subprocess
import sys
import time
import urllib.request
import urllib.error
import zipfile

API = "https://api.github.com"


def gh_get(path, token):
    req = urllib.request.Request(API + path)
    req.add_header("Authorization", "token " + token)
    req.add_header("Accept", "application/vnd.github+json")
    with urllib.request.urlopen(req, timeout=60) as r:
        return r.status, json.loads(r.read().decode() or "{}")


def run_cmd(cmd, cwd):
    r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True, shell=True)
    return r.returncode, r.stdout.strip(), r.stderr.strip()


def bump_version(pubspec_path, bump):
    with open(pubspec_path, encoding="utf-8") as f:
        txt = f.read()
    m = re.search(r"^version:\s*(\d+)\.(\d+)\.(\d+)\+(\d+)", txt, re.M)
    if not m:
        raise SystemExit("无法在 pubspec.yaml 解析 version: 行，请检查格式")
    major, minor, patch, code = map(int, m.groups())
    if bump == "major":
        major, minor, patch = major + 1, 0, 0
    elif bump == "minor":
        minor, patch = minor + 1, 0
    else:  # patch
        patch += 1
    code += 1
    new_ver = f"{major}.{minor}.{patch}+{code}"
    txt2 = re.sub(
        r"^version:\s*\d+\.\d+\.\d+\+\d+",
        f"version: {new_ver}",
        txt,
        flags=re.M,
    )
    with open(pubspec_path, "w", encoding="utf-8") as f:
        f.write(txt2)
    return new_ver, code


def find_new_run(owner, repo, token, head_sha, deadline):
    for _ in range(20):
        try:
            _, data = gh_get(
                f"/repos/{owner}/{repo}/actions/runs?per_page=10&branch=master", token
            )
        except Exception as e:
            print("[warn] 查询 runs 失败，重试:", e)
            time.sleep(10)
            continue
        for r in data.get("workflow_runs", []):
            if r.get("head_sha") == head_sha:
                return r["id"]
        if time.time() > deadline:
            break
        time.sleep(8)
    # 回退：取 master 上最近一次 run
    _, data = gh_get(
        f"/repos/{owner}/{repo}/actions/runs?per_page=1&branch=master", token
    )
    runs = data.get("workflow_runs", [])
    return runs[0]["id"] if runs else None


def main():
    ap = argparse.ArgumentParser(description="Flutter release 自动发布流程")
    ap.add_argument("--bump", default="patch", choices=["major", "minor", "patch"])
    ap.add_argument("--out-dir", default=r"D:/sleep_app/release_apk")
    ap.add_argument("--project-dir", default=os.getcwd())
    args = ap.parse_args()

    token = os.environ.get("GITHUB_TOKEN")
    if not token:
        raise SystemExit("缺少环境变量 GITHUB_TOKEN，无法访问 GitHub")

    proj = os.path.abspath(args.project_dir)
    pubspec = os.path.join(proj, "pubspec.yaml")
    if not os.path.isfile(pubspec):
        raise SystemExit("未找到 pubspec.yaml，请确认 --project-dir 指向 Flutter 工程根")

    # 解析 owner/repo
    rc, remote, _ = run_cmd("git remote get-url origin", proj)
    m = re.search(r"github\.com[:/]([^/]+)/([^/.]+)(?:\.git)?", remote)
    if not m:
        raise SystemExit("无法从 git remote 解析 owner/repo: " + remote)
    owner, repo = m.group(1), m.group(2)
    print(f"[info] 仓库: {owner}/{repo}")

    # 1. 版本自增
    new_ver, code = bump_version(pubspec, args.bump)
    print(f"[version] 版本更新为 {new_ver} (versionCode={code})")

    # 2. 提交
    rc, out, err = run_cmd(
        f'git add pubspec.yaml && git commit -q -m "chore(release): v{new_ver}"', proj
    )
    if rc != 0:
        print("[warn] commit 输出:", err or out)
        raise SystemExit("git commit 失败")

    # 3. 用 token 推送，推送完立即移除 token
    token_remote = f"https://{token}@github.com/{owner}/{repo}.git"
    run_cmd(f'git remote set-url origin "{token_remote}"', proj)
    rc, out, err = run_cmd("git push origin master", proj)
    run_cmd(f'git remote set-url origin "https://github.com/{owner}/{repo}.git"', proj)
    if rc != 0:
        print("[push stderr]", err)
        raise SystemExit("git push 失败")

    head_sha = run_cmd("git rev-parse HEAD", proj)[1]
    print(f"[push] 已推送，head_sha={head_sha[:8]}")

    # 4. 等待 CI
    deadline = time.time() + 35 * 60
    run_id = find_new_run(owner, repo, token, head_sha, deadline)
    if not run_id:
        raise SystemExit("未找到对应的 CI 运行记录")
    print(f"[ci] 运行 ID: {run_id}")

    final = None
    while time.time() < deadline:
        try:
            _, data = gh_get(f"/repos/{owner}/{repo}/actions/runs/{run_id}", token)
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

    # 5. 下载构件
    _, data = gh_get(f"/repos/{owner}/{repo}/actions/runs/{run_id}/artifacts", token)
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
    req = urllib.request.Request(
        f"{API}/repos/{owner}/{repo}/actions/artifacts/{art['id']}/zip"
    )
    req.add_header("Authorization", "token " + token)
    req.add_header("Accept", "application/vnd.github+json")
    print("[download] 开始下载构件 zip ...")
    with urllib.request.urlopen(req, timeout=600) as r, open(zip_path, "wb") as f:
        while True:
            buf = r.read(1024 * 1024)
            if not buf:
                break
            f.write(buf)
    print(f"[download] zip 已保存: {zip_path}")

    # 6. 解压出 app-release.apk
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
    os.remove(zip_path)

    size_mb = len(apk_bytes) / 1024 / 1024
    print("[done] 发布完成：")
    print(json.dumps({
        "version": new_ver,
        "versionCode": code,
        "apk_latest": latest_path,
        "apk_versioned": versioned_path,
        "size_mb": round(size_mb, 1),
    }, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
