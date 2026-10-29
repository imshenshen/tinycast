#!/usr/bin/env python3
"""fork-sync: check tinycast upstream, and inventory this fork's own changes.

Subcommands:
  check         fetch upstream, list commits since the last check, update state
  diff          list local fork changes against the fork base (with upstream overlap)
  status        print the recorded state, no network
  mark-ported   mark a pending upstream commit as ported
  drop          stop tracking a pending upstream commit

The state file sits next to SKILL.md (state.json) and is the record of when
upstream was last checked, what it contained, and what the user decided.
"""

from __future__ import annotations

import argparse
import json
import subprocess
import sys
from datetime import datetime
from pathlib import Path

SKILL_DIR = Path(__file__).resolve().parent.parent
STATE_PATH = SKILL_DIR / "state.json"

# The skill and its feature record describe the fork; they are not fork features.
NON_FEATURE_PREFIXES = (".claude/",)
NON_FEATURE_FILES = {"docs/fork-features.md"}


def is_feature_path(path: str) -> bool:
    return not path.startswith(NON_FEATURE_PREFIXES) and path not in NON_FEATURE_FILES


def find_root() -> Path:
    for parent in SKILL_DIR.parents:
        if (parent / ".git").exists():
            return parent
    sys.exit(f"fork-sync: cannot find the repository root above {SKILL_DIR}")


ROOT = find_root()


def git(*args: str, check: bool = True) -> str:
    proc = subprocess.run(
        ["git", "-C", str(ROOT), *args],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if check and proc.returncode != 0:
        sys.exit("fork-sync: git " + " ".join(args) + " failed:\n" + proc.stderr.strip())
    return proc.stdout


def has_commit(ref: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", str(ROOT), "cat-file", "-e", f"{ref}^{{commit}}"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def is_ancestor(ancestor: str, descendant: str) -> bool:
    return (
        subprocess.run(
            ["git", "-C", str(ROOT), "merge-base", "--is-ancestor", ancestor, descendant],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        ).returncode
        == 0
    )


def load_state() -> dict:
    state = {
        "upstreamRemote": "upstream",
        "upstreamBranch": "main",
        "baseCommit": None,
        "baseTag": None,
        "lastCheck": None,
        "lastCheckedUpstream": None,
        "pending": [],
        "ported": [],
        "dropped": [],
    }
    if STATE_PATH.exists():
        state.update(json.loads(STATE_PATH.read_text(encoding="utf-8")))
    return state


def save_state(state: dict) -> None:
    STATE_PATH.write_text(
        json.dumps(state, ensure_ascii=False, indent=2) + "\n", encoding="utf-8"
    )


def now() -> str:
    return datetime.now().astimezone().isoformat(timespec="seconds")


def require_base(state: dict) -> str:
    base = state.get("baseCommit")
    if not base:
        sys.exit(
            "fork-sync: state.json has no baseCommit. Set it to the upstream commit "
            "the fork started from."
        )
    if not has_commit(base):
        sys.exit(f"fork-sync: baseCommit {base} is not in this clone.")
    return base


def upstream_ref(state: dict) -> str:
    return f"{state['upstreamRemote']}/{state['upstreamBranch']}"


def ensure_remote(state: dict) -> None:
    remotes = git("remote").split()
    if state["upstreamRemote"] not in remotes:
        sys.exit(
            f"fork-sync: remote '{state['upstreamRemote']}' is not configured. "
            f"Add it with: git remote add {state['upstreamRemote']} <url>"
        )


def fetch_upstream(state: dict) -> None:
    """Fetch the upstream remote, completing a shallow clone's history once."""
    remote = state["upstreamRemote"]
    if git("rev-parse", "--is-shallow-repository").strip() == "true":
        print("· 浅克隆：补全上游历史（只需一次）…")
        git("fetch", "--unshallow", "--tags", remote)
    print(f"· 获取 {remote} …")
    git("fetch", "--prune", "--tags", remote)


def commit_files(sha: str) -> list[str]:
    # --first-parent: a merge commit's default --cc diff lists nothing; its first-parent diff does.
    out = git("show", "--first-parent", "--name-only", "--format=", sha)
    return [line for line in out.splitlines() if line.strip()]


def commit_stat(sha: str) -> str:
    out = git("show", "--first-parent", "--shortstat", "--format=", sha)
    return " ".join(out.split())


def commits_between(start: str, head: str) -> list[dict]:
    fmt = "%H%x1f%ci%x1f%s%x1f%b%x1e"
    raw = git("log", "--reverse", "--topo-order", f"--format={fmt}", f"{start}..{head}")
    commits = []
    for record in raw.split("\x1e"):
        record = record.strip("\n")
        if not record:
            continue
        sha, date, subject, body = record.split("\x1f", 3)
        commits.append(
            {
                "sha": sha,
                "date": date.strip(),
                "subject": subject.strip(),
                "body": body.strip(),
            }
        )
    return commits


def local_changed_files(base: str) -> tuple[set[str], set[str]]:
    tracked = {
        path
        for path in git("diff", "--name-only", base).splitlines()
        if is_feature_path(path)
    }
    untracked = {
        path
        for path in git("ls-files", "--others", "--exclude-standard").splitlines()
        if is_feature_path(path)
    }
    return tracked, untracked


def print_commit_entry(index: int, entry: dict, marker: str) -> None:
    date = entry.get("date", "")[:10]
    print(f"{marker} {index}. {entry['sha'][:7]}  {date}  {entry['subject']}")
    files = entry.get("files", [])
    if files:
        shown = ", ".join(files[:6])
        if len(files) > 6:
            shown += f" 等 {len(files)} 个文件"
        print(f"     文件: {shown}")
    stat = entry.get("stat")
    if stat:
        print(f"     统计: {stat}")
    overlap = entry.get("overlap") or []
    if overlap:
        print(f"     ⚠ 与本地改动重叠: {', '.join(overlap)}")
    first_seen = entry.get("firstSeen")
    if first_seen:
        print(f"     首次发现: {first_seen}")


def cmd_check(_args: argparse.Namespace) -> None:
    state = load_state()
    base = require_base(state)
    ensure_remote(state)
    fetch_upstream(state)

    ref = upstream_ref(state)
    head = git("rev-parse", "--verify", ref).strip()
    previous_check = state.get("lastCheck")
    start = state.get("lastCheckedUpstream") or base
    if not has_commit(start):
        print(f"· 上次记录 {start[:7]} 不在本地历史中，改从基线 {base[:7]} 比较。")
        start = base
    if not is_ancestor(start, head):
        print(f"· {start[:7]} 不是上游 {head[:7]} 的祖先，改从基线 {base[:7]} 比较。")
        start = base
    if not is_ancestor(base, head):
        sys.exit(
            "fork-sync: 上游已经不再包含基线 "
            f"{base[:7]}（可能被强推/改历史），请人工确认 baseCommit。"
        )

    tracked, untracked = local_changed_files(base)
    local = tracked | untracked
    commits = commits_between(start, head)

    known = {e["sha"] for e in state["ported"]} | {
        e["sha"] for e in state["dropped"]
    }
    new_shas = {c["sha"] for c in commits}
    kept = [e for e in state["pending"] if e["sha"] not in new_shas]
    appended = []
    seen = {e["sha"] for e in kept}
    for commit in commits:
        sha = commit["sha"]
        if sha in known or sha in seen:
            continue
        files = commit_files(sha)
        appended.append(
            {
                "sha": sha,
                "short": sha[:7],
                "date": commit["date"],
                "subject": commit["subject"],
                "body": commit["body"],
                "files": files,
                "overlap": sorted(set(files) & local),
                "stat": commit_stat(sha),
                "firstSeen": now(),
            }
        )
        seen.add(sha)

    checked_at = now()
    state["lastCheck"] = checked_at
    state["lastCheckedUpstream"] = head
    state["pending"] = kept + appended
    save_state(state)

    print()
    print("=== 上游检查 ===")
    tag = f" ({state['baseTag']})" if state.get("baseTag") else ""
    print(f"fork 基线 : {base[:7]}{tag}")
    print(f"上游      : {ref} @ {head[:7]}")
    print(f"上次检查  : {previous_check or '从未'}")
    print(f"本次检查  : {checked_at}")
    print(f"新增提交  : {len(appended)}")
    print(f"待处理    : {len(state['pending'])}")

    if appended:
        print()
        print("--- 本次新增 ---")
        for i, entry in enumerate(appended, 1):
            print_commit_entry(i, entry, "[新]")

    if kept:
        print()
        print("--- 以前发现、仍未处理 ---")
        for i, entry in enumerate(kept, 1):
            print_commit_entry(i, entry, "[待]")

    if state["pending"]:
        print()
        print("待处理清单（按此编号让用户选择）:")
        for i, entry in enumerate(state["pending"], 1):
            warn = "  ⚠ 与本地改动重叠" if entry.get("overlap") else ""
            print(f"  {i}) {entry['sha'][:7]}  {entry['subject']}{warn}")
    else:
        print()
        print("没有待处理的上游提交。")


def cmd_diff(args: argparse.Namespace) -> None:
    state = load_state()
    base = require_base(state)
    if args.fetch:
        ensure_remote(state)
        fetch_upstream(state)

    ref = upstream_ref(state)
    head = git("rev-parse", "--verify", ref, check=False).strip()
    tracked, untracked = local_changed_files(base)

    status: dict[str, str] = {}
    for line in git("diff", "--name-status", base).splitlines():
        parts = line.split("\t")
        if len(parts) >= 2:
            status[parts[-1]] = parts[0]

    numstat: dict[str, tuple[str, str]] = {}
    for line in git("diff", "--numstat", base).splitlines():
        parts = line.split("\t")
        if len(parts) == 3:
            numstat[parts[2]] = (parts[0], parts[1])

    upstream_changed: set[str] = set()
    upstream_has_untracked: set[str] = set()
    if head:
        upstream_changed = set(git("diff", "--name-only", f"{base}..{head}").splitlines())
        for path in untracked:
            if has_commit(f"{head}:{path}"):
                upstream_has_untracked.add(path)

    adds = sum(int(a) for a, _ in numstat.values() if a.isdigit())
    dels = sum(int(d) for _, d in numstat.values() if d.isdigit())

    print("=== Fork 变更（相对基线）===")
    tag = f" ({state['baseTag']})" if state.get("baseTag") else ""
    print(f"fork 基线 : {base[:7]}{tag}")
    if head:
        same = "（与基线相同）" if head == base else ""
        print(f"上游      : {ref} @ {head[:7]}{same}")
    else:
        print(f"上游      : {ref} 尚未获取（先运行 check）")
    print(f"已跟踪改动: {len(tracked)} 个文件，+{adds} / -{dels}")
    print(f"未跟踪新文件: {len(untracked)}")
    print()

    print(f"{'状态':<5} {'增':>6} {'删':>6}  {'上游已改':<8} 文件")
    for path in sorted(tracked):
        a, d = numstat.get(path, ("-", "-"))
        touched = path in upstream_changed
        print(f"{status.get(path, 'M'):<5} {a:>6} {d:>6}  {'是' if touched else '否':<8} {path}")
    for path in sorted(untracked):
        touched = path in upstream_has_untracked
        print(f"{'新':<5} {'-':>6} {'-':>6}  {'是' if touched else '否':<8} {path}")

    only_upstream = sorted(upstream_changed - tracked - untracked)
    print()
    print(f"上游自基线后改动、本地未改的文件: {len(only_upstream)}")
    for path in only_upstream:
        print(f"  {path}")
    print()
    print("提示：上游已改为「是」的文件，在引用上游改动时最可能冲突。")


def cmd_status(_args: argparse.Namespace) -> None:
    state = load_state()
    ref = upstream_ref(state)
    head = git("rev-parse", "--verify", ref, check=False).strip()
    print("=== fork-sync 状态 ===")
    print(f"fork 基线   : {state.get('baseCommit') or '未设置'}"
          + (f" ({state['baseTag']})" if state.get("baseTag") else ""))
    print(f"上游        : {ref}" + (f" @ {head[:7]}" if head else "（未获取）"))
    print(f"上次检查    : {state.get('lastCheck') or '从未'}")
    print(f"上次检查到  : {state.get('lastCheckedUpstream') or '—'}")
    print(f"待处理      : {len(state['pending'])}")
    for i, entry in enumerate(state["pending"], 1):
        print(f"  {i}) {entry['sha'][:7]}  {entry['subject']}")
    print(f"已引用      : {len(state['ported'])}")
    for entry in state["ported"]:
        print(f"  {entry['sha'][:7]}  {entry['subject']}  ({entry.get('portedAt', '')})")
    print(f"已放弃      : {len(state['dropped'])}")
    for entry in state["dropped"]:
        print(f"  {entry['sha'][:7]}  {entry['subject']}  ({entry.get('droppedAt', '')})")


def find_pending(state: dict, prefix: str) -> dict:
    matches = [e for e in state["pending"] if e["sha"].startswith(prefix)]
    if not matches:
        sys.exit(f"fork-sync: 待处理清单里没有 {prefix}")
    if len(matches) > 1:
        sys.exit(f"fork-sync: 前缀 {prefix} 匹配多个提交，请写长一点")
    return matches[0]


def cmd_mark_ported(args: argparse.Namespace) -> None:
    state = load_state()
    entry = find_pending(state, args.sha)
    state["pending"] = [e for e in state["pending"] if e["sha"] != entry["sha"]]
    entry["portedAt"] = now()
    entry["note"] = args.note
    state["ported"].append(entry)
    save_state(state)
    print(f"已标记引用: {entry['sha'][:7]}  {entry['subject']}")
    if args.note:
        print(f"备注: {args.note}")


def cmd_drop(args: argparse.Namespace) -> None:
    state = load_state()
    entry = find_pending(state, args.sha)
    state["pending"] = [e for e in state["pending"] if e["sha"] != entry["sha"]]
    entry["droppedAt"] = now()
    entry["note"] = args.note
    state["dropped"].append(entry)
    save_state(state)
    print(f"已停止跟踪: {entry['sha'][:7]}  {entry['subject']}")
    if args.note:
        print(f"备注: {args.note}")


def main() -> None:
    parser = argparse.ArgumentParser(
        prog="fork_sync.py",
        description="检查 tinycast 上游更新，并盘点 fork 自身改动。",
    )
    sub = parser.add_subparsers(dest="command", required=True)

    sub.add_parser("check", help="获取上游并列出上次检查以来的新提交")
    p_diff = sub.add_parser("diff", help="列出相对 fork 基线的本地改动")
    p_diff.add_argument(
        "--fetch", action="store_true", help="先获取上游（默认不联网）"
    )
    sub.add_parser("status", help="打印状态，不联网")

    p_port = sub.add_parser("mark-ported", help="标记某个上游提交已引用")
    p_port.add_argument("sha", help="提交 SHA 或其唯一前缀")
    p_port.add_argument("note", nargs="?", default="", help="备注")

    p_drop = sub.add_parser("drop", help="不再跟踪某个上游提交")
    p_drop.add_argument("sha", help="提交 SHA 或其唯一前缀")
    p_drop.add_argument("note", nargs="?", default="", help="原因")

    args = parser.parse_args()
    handlers = {
        "check": cmd_check,
        "diff": cmd_diff,
        "status": cmd_status,
        "mark-ported": cmd_mark_ported,
        "drop": cmd_drop,
    }
    handlers[args.command](args)


if __name__ == "__main__":
    main()
