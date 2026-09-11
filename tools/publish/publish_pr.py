#!/usr/bin/env python3
"""Publish the Mewjector issue and pull request, once, non-interactive.

    GITHUB_TOKEN=<classic token with public_repo> \
        nix shell nixpkgs#git nixpkgs#python3 --command \
        python3 tools/publish/publish_pr.py

    ... --dry-run     stop after the token and fork checks; publish nothing

Idempotent: reuses an existing fork, branch, issue or PR instead of duplicating.
The token is read from the environment, injected into git through config env
vars (never argv, never on disk), and is never printed.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
PATCH = REPO / "patches" / "mewjector-epfallback-and-logging.patch"
COMMIT_MSG = HERE / "commit_msg.txt"
PR_BODY = HERE / "pr_body.md"
ISSUE_BODY = HERE / "issue_body.md"
CLONE_DIR = Path("/tmp/mewgenics-publish/mewjector-fork")

API = "https://api.github.com"
UPSTREAM = "githubuser508/mewjector"
BASE_BRANCH = "main"
BRANCH = "fix/ep-fallback-optout-and-logging"
ISSUE_TITLE = ("Intermittent startup hang under Proton before mods load "
               "(entry-point fallback)")
PR_TITLE = "Add Chainloader/EnableEPFallback opt-out and honour Logging=0"

TOKEN = os.environ.get("GITHUB_TOKEN", "").strip()


def call(method: str, path: str, payload=None):
    url = path if path.startswith("http") else API + path
    data = json.dumps(payload).encode() if payload is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    for key, value in (
        ("Authorization", "Bearer " + TOKEN),
        ("Accept", "application/vnd.github+json"),
        ("X-GitHub-Api-Version", "2022-11-28"),
        ("User-Agent", "mewgenics-overlay-bridge"),
    ):
        req.add_header(key, value)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return resp.status, dict(resp.headers), resp.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as exc:
        return exc.code, dict(exc.headers), exc.read().decode("utf-8", "replace")


def need(ok: bool, message: str, detail: str = "") -> None:
    if not ok:
        sys.exit(f"error: {message}\n{detail[:600]}")


def read(path: Path) -> str:
    return path.read_text(encoding="utf-8")


def git(*args: str, check: bool = True) -> subprocess.CompletedProcess:
    env = dict(os.environ)
    env["GIT_TERMINAL_PROMPT"] = "0"
    env["GIT_CONFIG_COUNT"] = "1"
    env["GIT_CONFIG_KEY_0"] = "http.extraHeader"
    env["GIT_CONFIG_VALUE_0"] = "Authorization: Bearer " + TOKEN
    cwd = str(CLONE_DIR) if CLONE_DIR.is_dir() else None
    result = subprocess.run(["git", *args], cwd=cwd, env=env,
                            capture_output=True, text=True)
    if check and result.returncode != 0:
        combined = (result.stdout + result.stderr).replace(TOKEN, "***")
        sys.exit(f"error: git {' '.join(args)} failed ({result.returncode})\n"
                 f"{combined[-800:]}")
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dry-run", action="store_true",
                        help="check token and fork only; publish nothing")
    args = parser.parse_args()

    if not TOKEN:
        sys.exit("error: GITHUB_TOKEN is not set")
    if not PATCH.is_file():
        sys.exit(f"error: patch not found at {PATCH}")

    status, headers, body = call("GET", "/user")
    need(status == 200, f"token check failed ({status})", body)
    login = json.loads(body)["login"]
    print(f"authenticated as {login}")
    print(f"token scopes: {headers.get('X-OAuth-Scopes', '(not reported)')}")

    status, _, _ = call("GET", f"/repos/{login}/mewjector")
    fork_exists = status == 200
    print(f"fork: {'exists' if fork_exists else 'not created yet'} "
          f"(https://github.com/{login}/mewjector)")

    if args.dry_run:
        print("\ndry run: token is valid, nothing was published")
        return 0

    if not fork_exists:
        status, _, body = call("POST", f"/repos/{UPSTREAM}/forks", {})
        need(status in (200, 202), f"could not create the fork ({status})", body)
        print("fork requested; waiting for it to become available ...")
        for _ in range(40):
            time.sleep(3)
            status, _, _ = call("GET", f"/repos/{login}/mewjector")
            if status == 200:
                break
        need(status == 200, "fork did not become available in time", "")
        print(f"fork ready: https://github.com/{login}/mewjector")

    shutil.rmtree(CLONE_DIR, ignore_errors=True)
    CLONE_DIR.parent.mkdir(parents=True, exist_ok=True)
    git("clone", "--quiet", f"https://github.com/{login}/mewjector.git", str(CLONE_DIR))
    git("checkout", "--quiet", BASE_BRANCH)
    git("checkout", "--quiet", "-B", BRANCH)

    check = subprocess.run(["git", "apply", "--check", str(PATCH)],
                           cwd=str(CLONE_DIR), capture_output=True, text=True)
    need(check.returncode == 0, "patch does not apply to the fork",
         check.stdout + check.stderr)
    git("apply", str(PATCH))
    identity = ["-c", f"user.name={login}",
                "-c", f"user.email={login}@users.noreply.github.com"]
    git(*identity, "add", "version.c", "chainloader.ini")
    git(*identity, "commit", "--quiet", "-F", str(COMMIT_MSG))
    print("commit:", git("log", "--oneline", "-1").stdout.strip())

    git("push", "--quiet", "origin", "--delete", BRANCH, check=False)
    push = git("push", "--quiet", "-u", "origin", BRANCH, check=False)
    need(push.returncode == 0, "push failed", push.stdout + push.stderr)
    print(f"pushed branch: https://github.com/{login}/mewjector/tree/{BRANCH}")

    issue_number = None
    status, _, body = call(
        "GET", f"/repos/{UPSTREAM}/issues?state=all&creator={login}&per_page=100")
    if status == 200:
        for item in json.loads(body):
            if item.get("title") == ISSUE_TITLE and "pull_request" not in item:
                issue_number = item["number"]
                break
    if issue_number is None:
        status, _, body = call("POST", f"/repos/{UPSTREAM}/issues",
                               {"title": ISSUE_TITLE, "body": read(ISSUE_BODY)})
        need(status == 201, f"could not create the issue ({status})", body)
        issue_number = json.loads(body)["number"]
        print(f"issue created: https://github.com/{UPSTREAM}/issues/{issue_number}")
    else:
        print(f"issue already exists: "
              f"https://github.com/{UPSTREAM}/issues/{issue_number}")

    pr_body = read(PR_BODY).rstrip() + f"\n\nRefs #{issue_number}\n"
    pr_url = None
    status, _, body = call(
        "GET", f"/repos/{UPSTREAM}/pulls?state=open&head={login}:{BRANCH}")
    if status == 200:
        for item in json.loads(body):
            if item.get("head", {}).get("ref") == BRANCH:
                pr_url = item["html_url"]
                break
    if pr_url is None:
        status, _, body = call("POST", f"/repos/{UPSTREAM}/pulls",
                               {"title": PR_TITLE, "head": f"{login}:{BRANCH}",
                                "base": BASE_BRANCH, "body": pr_body})
        need(status == 201, f"could not create the pull request ({status})", body)
        pr_url = json.loads(body)["html_url"]
        print(f"pull request created: {pr_url}")
    else:
        print(f"pull request already exists: {pr_url}")

    print("\nDONE")
    print(f"issue: https://github.com/{UPSTREAM}/issues/{issue_number}")
    print(f"pr:    {pr_url}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
