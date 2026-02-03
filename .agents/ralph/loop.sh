#!/bin/bash
# Ralph loop — simple, portable, single-agent
# Usage:
#   ./.agents/ralph/loop.sh                 # build mode, default iterations
#   ./.agents/ralph/loop.sh build           # build mode
#   ./.agents/ralph/loop.sh prd "request"   # generate PRD via agent
#   ./.agents/ralph/loop.sh 10              # build mode, 10 iterations
#   ./.agents/ralph/loop.sh build 1 --no-commit

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${RALPH_ROOT:-${SCRIPT_DIR}/../..}" && pwd)"
CONFIG_FILE="${SCRIPT_DIR}/config.sh"

DEFAULT_PRD_PATH=".agents/tasks/prd.json"
DEFAULT_PROGRESS_PATH=".ralph/progress.md"
DEFAULT_AGENTS_PATH="AGENTS.md"
DEFAULT_PROMPT_BUILD=".agents/ralph/PROMPT_build.md"
DEFAULT_GUARDRAILS_PATH=".ralph/guardrails.md"
DEFAULT_ERRORS_LOG_PATH=".ralph/errors.log"
DEFAULT_ACTIVITY_LOG_PATH=".ralph/activity.log"
DEFAULT_TMP_DIR=".ralph/.tmp"
DEFAULT_RUNS_DIR=".ralph/runs"
DEFAULT_GUARDRAILS_REF=".agents/ralph/references/GUARDRAILS.md"
DEFAULT_CONTEXT_REF=".agents/ralph/references/CONTEXT_ENGINEERING.md"
DEFAULT_ACTIVITY_CMD=".agents/ralph/log-activity.sh"
if [[ -n "${RALPH_ROOT:-}" ]]; then
  agents_path="$RALPH_ROOT/.agents/ralph/agents.sh"
else
  agents_path="$SCRIPT_DIR/agents.sh"
fi
if [[ -f "$agents_path" ]]; then
  # shellcheck source=/dev/null
  source "$agents_path"
fi

DEFAULT_MAX_ITERATIONS=25
DEFAULT_NO_COMMIT=false
DEFAULT_STALE_SECONDS=0
PRD_REQUEST_PATH=""
PRD_INLINE=""

# Optional config overrides (simple shell vars)
if [ -f "$CONFIG_FILE" ]; then
  # shellcheck source=/dev/null
  . "$CONFIG_FILE"
fi

DEFAULT_AGENT_NAME="${DEFAULT_AGENT:-codex}"
resolve_agent_cmd() {
  local name="$1"
  case "$name" in
    claude)
      echo "${AGENT_CLAUDE_CMD:-claude -p --dangerously-skip-permissions \"\$(cat {prompt})\"}"
      ;;
    droid)
      echo "${AGENT_DROID_CMD:-droid exec --skip-permissions-unsafe -f {prompt}}"
      ;;
    codex|"")
      echo "${AGENT_CODEX_CMD:-codex exec --yolo --skip-git-repo-check -}"
      ;;
    glm)
      echo "${AGENT_GLM_CMD:-claude -p --fork-session --dangerously-skip-permissions --settings ~/.claude/zai-settings.json \"\$(cat {prompt})\"}"
      ;;
    kimi)
      echo "${AGENT_KIMI_CMD:-claude -p --fork-session --dangerously-skip-permissions --settings ~/.claude/kimi-settings.json \"\$(cat {prompt})\"}"
      ;;
    *)
      echo "${AGENT_CODEX_CMD:-codex exec --yolo --skip-git-repo-check -}"
      ;;
  esac
}
DEFAULT_AGENT_CMD="$(resolve_agent_cmd "$DEFAULT_AGENT_NAME")"

PRD_PATH="${PRD_PATH:-$DEFAULT_PRD_PATH}"
PROGRESS_PATH="${PROGRESS_PATH:-$DEFAULT_PROGRESS_PATH}"
AGENTS_PATH="${AGENTS_PATH:-$DEFAULT_AGENTS_PATH}"
PROMPT_BUILD="${PROMPT_BUILD:-$DEFAULT_PROMPT_BUILD}"
GUARDRAILS_PATH="${GUARDRAILS_PATH:-$DEFAULT_GUARDRAILS_PATH}"
ERRORS_LOG_PATH="${ERRORS_LOG_PATH:-$DEFAULT_ERRORS_LOG_PATH}"
ACTIVITY_LOG_PATH="${ACTIVITY_LOG_PATH:-$DEFAULT_ACTIVITY_LOG_PATH}"
TMP_DIR="${TMP_DIR:-$DEFAULT_TMP_DIR}"
RUNS_DIR="${RUNS_DIR:-$DEFAULT_RUNS_DIR}"
GUARDRAILS_REF="${GUARDRAILS_REF:-$DEFAULT_GUARDRAILS_REF}"
CONTEXT_REF="${CONTEXT_REF:-$DEFAULT_CONTEXT_REF}"
ACTIVITY_CMD="${ACTIVITY_CMD:-$DEFAULT_ACTIVITY_CMD}"
AGENT_CMD="${AGENT_CMD:-$DEFAULT_AGENT_CMD}"
MAX_ITERATIONS="${MAX_ITERATIONS:-$DEFAULT_MAX_ITERATIONS}"
NO_COMMIT="${NO_COMMIT:-$DEFAULT_NO_COMMIT}"
STALE_SECONDS="${STALE_SECONDS:-$DEFAULT_STALE_SECONDS}"

abs_path() {
  local p="$1"
  if [[ "$p" = /* ]]; then
    echo "$p"
  else
    echo "$ROOT_DIR/$p"
  fi
}

PRD_PATH="$(abs_path "$PRD_PATH")"
PROGRESS_PATH="$(abs_path "$PROGRESS_PATH")"
AGENTS_PATH="$(abs_path "$AGENTS_PATH")"
PROMPT_BUILD="$(abs_path "$PROMPT_BUILD")"
GUARDRAILS_PATH="$(abs_path "$GUARDRAILS_PATH")"
ERRORS_LOG_PATH="$(abs_path "$ERRORS_LOG_PATH")"
ACTIVITY_LOG_PATH="$(abs_path "$ACTIVITY_LOG_PATH")"
TMP_DIR="$(abs_path "$TMP_DIR")"
RUNS_DIR="$(abs_path "$RUNS_DIR")"
GUARDRAILS_REF="$(abs_path "$GUARDRAILS_REF")"
CONTEXT_REF="$(abs_path "$CONTEXT_REF")"
# ACTIVITY_CMD is a shell command, not a file path - don't abs_path it
# ACTIVITY_CMD="$(abs_path "$ACTIVITY_CMD")"

require_agent() {
  local agent_cmd="${1:-$AGENT_CMD}"
  local agent_bin
  agent_bin="${agent_cmd%% *}"
  if [ -z "$agent_bin" ]; then
    echo "AGENT_CMD is empty. Set it in config.sh."
    exit 1
  fi
  if ! command -v "$agent_bin" >/dev/null 2>&1; then
    echo "Agent command not found: $agent_bin"
    case "$agent_bin" in
      codex)
        echo "Install: npm i -g @openai/codex"
        ;;
      claude)
        echo "Install: curl -fsSL https://claude.ai/install.sh | bash"
        ;;
      droid)
        echo "Install: curl -fsSL https://app.factory.ai/cli | sh"
        ;;
      opencode)
        echo "Install: curl -fsSL https://opencode.ai/install.sh | bash"
        ;;
    esac
    echo "Then authenticate per the CLI's instructions."
    exit 1
  fi
}

run_agent() {
  local prompt_file="$1"
  local output
  local exit_code
  local cmd="$AGENT_CMD"

  # Inject --settings if RALPH_SETTINGS is set
  if [[ -n "${RALPH_SETTINGS:-}" ]]; then
    # Insert --settings after the agent binary name
    # e.g., "claude -p ..." -> "claude --settings ~/.claude/custom.json -p ..."
    if [[ "$cmd" =~ ^([a-z][a-z0-9_-]*)\  ]]; then
      local agent_bin="${BASH_REMATCH[1]}"
      cmd="${cmd/#$agent_bin /$agent_bin --settings \"$RALPH_SETTINGS\" }"
    fi
  fi

  if [[ "$cmd" == *"{prompt}"* ]]; then
    local escaped
    escaped=$(printf '%q' "$prompt_file")
    cmd="${cmd//\{prompt\}/$escaped}"
    output=$(eval "$cmd" 2>&1)
    exit_code=$?
  else
    output=$(cat "$prompt_file" | eval "$cmd" 2>&1)
    exit_code=$?
  fi

  # Check for Claude CLI "No messages returned" error
  if echo "$output" | grep -q "No messages returned"; then
    # This error occurs when Claude tries to resume a thread with no messages
    # Clear conversation state and retry with --fresh flag
    echo "[Ralph] 'No messages returned' error detected. Clearing conversation state and retrying with --fresh..." >&2
    local claude_dir="$HOME/.claude"
    local conversations_dir="$claude_dir/conversations"
    if [ -d "$conversations_dir" ]; then
      # Find and remove the most recent conversation (likely the problematic one)
      local latest_conv
      latest_conf="$(find "$conversations_dir" -type f -name "*.json" -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -d' ' -f2-)"
      if [ -n "$latest_conf" ]; then
        echo "[Ralph] Clearing conversation state: $latest_conf" >&2
        rm -f "$latest_conf"
      fi
    fi

    # Retry with fresh conversation (add --fresh for Claude)
    local retry_cmd="$AGENT_CMD"
    # Inject --settings if RALPH_SETTINGS is set
    if [[ -n "${RALPH_SETTINGS:-}" ]]; then
      if [[ "$retry_cmd" =~ ^([a-z][a-z0-9_-]*)\  ]]; then
        local agent_bin="${BASH_REMATCH[1]}"
        retry_cmd="${retry_cmd/#$agent_bin /$agent_bin --settings \"$RALPH_SETTINGS\" }"
      fi
    fi
    if [[ "$retry_cmd" == *"{prompt}"* ]]; then
      local escaped
      escaped=$(printf '%q' "$prompt_file")
      local cmd="${retry_cmd//\{prompt\}/$escaped}"
      # Insert --fresh after 'claude' if not already present
      if [[ "$cmd" =~ claude\  ]] && [[ ! "$cmd" =~ --fresh ]]; then
        cmd="${cmd/claude /claude --fresh }"
      fi
      echo "[Ralph] Retrying with --fresh flag..." >&2
      output=$(eval "$cmd" 2>&1)
      exit_code=$?
    else
      # For piped commands, add --fresh flag
      local fresh_cmd="${retry_cmd/claude /claude --fresh }"
      echo "[Ralph] Retrying with --fresh flag..." >&2
      output=$(cat "$prompt_file" | eval "$fresh_cmd" 2>&1)
      exit_code=$?
    fi

    # Check if retry also failed with "No messages returned"
    if echo "$output" | grep -q "No messages returned"; then
      echo "[Ralph] ERROR: Retry also failed with 'No messages returned'. This may indicate a deeper issue with the Claude CLI state." >&2
      log_error "Agent retry failed: 'No messages returned' error persisted after --fresh retry"
    fi
  fi

  # Detect and report common script errors that might cause hangs or failed completion
  if [ "$exit_code" -ne 0 ]; then
    # Check for specific error patterns
    if echo "$output" | grep -qiE "(SyntaxError|Traceback|TypeError|ReferenceError|undefined is not a function|Cannot read|script error|permission denied|command not found|No messages returned)"; then
      echo "[Ralph] WARNING: Script error detected in agent output!" >&2
      echo "[Ralph] The agent may have encountered a runtime error that prevented completion." >&2
    fi
  fi

  # Detect potential hangs (interactive prompts, waiting for input)
  if echo "$output" | grep -qiE "(waiting for input|press any key|continue\?|\[Y/n\]|\\(yes/no\\)|enter to continue|interactive prompt)"; then
    echo "[Ralph] WARNING: Agent may be waiting for interactive input!" >&2
    echo "[Ralph] This can cause the build to hang. Consider using non-interactive flags." >&2
  fi

  printf '%s\n' "$output"
  return "$exit_code"
}

run_agent_inline() {
  local prompt_file="$1"
  local prompt_content
  prompt_content="$(cat "$prompt_file")"
  local escaped
  escaped=$(printf "%s" "$prompt_content" | sed "s/'/'\\\\''/g")
  local cmd="${PRD_AGENT_CMD:-$AGENT_CMD}"

  # Inject --settings if RALPH_SETTINGS is set
  if [[ -n "${RALPH_SETTINGS:-}" ]]; then
    if [[ "$cmd" =~ ^([a-z][a-z0-9_-]*)\  ]]; then
      local agent_bin="${BASH_REMATCH[1]}"
      cmd="${cmd/#$agent_bin /$agent_bin --settings \"$RALPH_SETTINGS\" }"
    fi
  fi

  if [[ "$cmd" == *"{prompt}"* ]]; then
    cmd="${cmd//\{prompt\}/'$escaped'}"
  else
    cmd="$cmd '$escaped'"
  fi
  eval "$cmd"
}

MODE="build"
while [ $# -gt 0 ]; do
  case "$1" in
    build|prd)
      MODE="$1"
      shift
      ;;
    --prompt)
      PRD_REQUEST_PATH="$2"
      shift 2
      ;;
    --no-commit)
      NO_COMMIT=true
      shift
      ;;
    *)
      if [ "$MODE" = "prd" ]; then
        PRD_INLINE="${PRD_INLINE:+$PRD_INLINE }$1"
        shift
      elif [[ "$1" =~ ^[0-9]+$ ]]; then
        MAX_ITERATIONS="$1"
        shift
      else
        echo "Unknown arg: $1"
        exit 1
      fi
      ;;
  esac
done

PROMPT_FILE="$PROMPT_BUILD"

if [ "$MODE" = "prd" ]; then
  PRD_USE_INLINE=1
  if [ -z "${PRD_AGENT_CMD:-}" ]; then
    PRD_AGENT_CMD="$AGENT_CMD"
    PRD_USE_INLINE=0
  fi
  if [ "${RALPH_DRY_RUN:-}" != "1" ]; then
    require_agent "${PRD_AGENT_CMD:-$AGENT_CMD}"
  fi

  if [[ "$PRD_PATH" == *.json ]]; then
    mkdir -p "$(dirname "$PRD_PATH")" "$TMP_DIR"
  else
    mkdir -p "$PRD_PATH" "$TMP_DIR"
  fi

  if [ -z "$PRD_REQUEST_PATH" ] && [ -n "$PRD_INLINE" ]; then
    PRD_REQUEST_PATH="$TMP_DIR/prd-request-$(date +%Y%m%d-%H%M%S)-$$.txt"
    printf '%s\n' "$PRD_INLINE" > "$PRD_REQUEST_PATH"
  fi

  if [ -z "$PRD_REQUEST_PATH" ] || [ ! -f "$PRD_REQUEST_PATH" ]; then
    echo "PRD request missing. Provide a prompt string or --prompt <file>."
    exit 1
  fi

  if [ "${RALPH_DRY_RUN:-}" = "1" ]; then
    if [[ "$PRD_PATH" == *.json ]]; then
      if [ ! -f "$PRD_PATH" ]; then
        {
          echo '{'
          echo '  "version": 1,'
          echo '  "project": "ralph",'
          echo '  "qualityGates": [],'
          echo '  "stories": []'
          echo '}'
        } > "$PRD_PATH"
      fi
    fi
    exit 0
  fi

  PRD_PROMPT_FILE="$TMP_DIR/prd-prompt-$(date +%Y%m%d-%H%M%S)-$$.md"
  {
    echo "You are an autonomous coding agent."
    echo "Use the \$prd skill to create a Product Requirements Document in JSON."
    if [[ "$PRD_PATH" == *.json ]]; then
      echo "Save the PRD to: $PRD_PATH"
    else
      echo "Save the PRD as JSON in directory: $PRD_PATH"
      echo "Filename rules: prd-<short-slug>.json using 1-3 meaningful words."
      echo "Examples: prd-workout-tracker.json, prd-usage-billing.json"
    fi
    echo "Do NOT implement anything."
    echo "After creating the PRD, end with:"
    echo "PRD JSON saved to <path>. Close this chat and run \`ralph build\`."
    echo ""
    echo "User request:"
    cat "$PRD_REQUEST_PATH"
  } > "$PRD_PROMPT_FILE"

  if [ "$PRD_USE_INLINE" -eq 1 ]; then
    run_agent_inline "$PRD_PROMPT_FILE"
  else
    run_agent "$PRD_PROMPT_FILE"
  fi
  exit 0
fi

if [ "${RALPH_DRY_RUN:-}" != "1" ]; then
  require_agent
fi

if [ ! -f "$PROMPT_FILE" ]; then
  echo "Prompt not found: $PROMPT_FILE"
  exit 1
fi

if [ "$MODE" != "prd" ] && [ ! -f "$PRD_PATH" ]; then
  echo "PRD not found: $PRD_PATH"
  exit 1
fi

mkdir -p "$(dirname "$PROGRESS_PATH")" "$TMP_DIR" "$RUNS_DIR"

if [ ! -f "$PROGRESS_PATH" ]; then
  {
    echo "# Progress Log"
    echo "Started: $(date)"
    echo ""
    echo "## Codebase Patterns"
    echo "- (add reusable patterns here)"
    echo ""
    echo "---"
  } > "$PROGRESS_PATH"
fi

if [ ! -f "$GUARDRAILS_PATH" ]; then
  {
    echo "# Guardrails (Signs)"
    echo ""
    echo "> Lessons learned from failures. Read before acting."
    echo ""
    echo "## Core Signs"
    echo ""
    echo "### Sign: Read Before Writing"
    echo "- **Trigger**: Before modifying any file"
    echo "- **Instruction**: Read the file first"
    echo "- **Added after**: Core principle"
    echo ""
    echo "### Sign: Test Before Commit"
    echo "- **Trigger**: Before committing changes"
    echo "- **Instruction**: Run required tests and verify outputs"
    echo "- **Added after**: Core principle"
    echo ""
    echo "---"
    echo ""
    echo "## Learned Signs"
    echo ""
  } > "$GUARDRAILS_PATH"
fi

# Add the PRD completion guardrail if not already present
if ! grep -q "PRD Complete Before Story Done" "$GUARDRAILS_PATH" 2>/dev/null; then
  {
    echo "### Sign: PRD Complete Before Story Done"
    echo "- **Trigger**: Before outputting \`<promise>COMPLETE</promise>\`"
    echo "- **Instruction**: Story is NOT complete until the PRD JSON status is updated to \"done\""
    echo "- **Why**: The PRD is the source of truth. Without this update, the story will be re-picked in future iterations."
    echo "- **Action**: Before completing, verify the story's status in the PRD shows \"done\", not \"in_progress\" or \"open\""
    echo "- **Added after**: Stories being marked complete in code but PRD staying stale, causing redundant work"
    echo ""
  } >> "$GUARDRAILS_PATH"
fi

# Add the completion signal format guardrail if not already present
if ! grep -q "Completion Signal Must Be Standalone" "$GUARDRAILS_PATH" 2>/dev/null; then
  {
    echo "### Sign: Completion Signal Must Be Standalone"
    echo "- **Trigger**: When outputting the completion signal"
    echo "- **Instruction**: The completion signal MUST be on its own line with exact formatting"
    echo "- **Format**: \`<promise>COMPLETE</promise>\` (case-sensitive, no extra spaces in tags)"
    echo "- **Why**: The build loop uses grep to detect completion. Merged or malformed signals won't be detected."
    echo "- **Examples**:"
    echo "  - ✅ CORRECT: The final line of output is just \`<promise>COMPLETE</promise>\`"
    echo "  - ❌ WRONG: \"Done! <promise>COMPLETE</promise>\" (merged with text)"
    echo "  - ❌ WRONG: \"<promise>complete</promise>\" (wrong case)"
    echo "- **Added after**: Agents outputting completion signals that weren't detected, causing stories to be reset to open"
    echo ""
  } >> "$GUARDRAILS_PATH"
fi

# Add the avoid interactive prompts guardrail if not already present
if ! grep -q "Avoid Interactive Prompts" "$GUARDRAILS_PATH" 2>/dev/null; then
  {
    echo "### Sign: Avoid Interactive Prompts"
    echo "- **Trigger**: Before running any command that might prompt for input"
    echo "- **Instruction**: Never run commands that require interactive input. Always use non-interactive flags."
    echo "- **Why**: Interactive prompts cause the build to hang indefinitely, waiting for user input."
    echo "- **Examples**:"
    echo "  - ❌ WRONG: \`npm install\` (may prompt for permissions)"
    echo "  - ✅ CORRECT: \`npm install --yes --silent\`"
    echo "  - ❌ WRONG: \`pip install package\` (may prompt for confirmation)"
    echo "  - ✅ CORRECT: \`pip install package --quiet --no-input\`"
    echo "  - ❌ WRONG: \`apt-get install package\` (prompts for confirmation)"
    echo "  - ✅ CORRECT: \`apt-get install -y package\`"
    echo "- **Added after**: Build hangs caused by commands waiting for interactive input"
    echo ""
  } >> "$GUARDRAILS_PATH"
fi

if [ ! -f "$ERRORS_LOG_PATH" ]; then
  {
    echo "# Error Log"
    echo ""
    echo "> Failures and repeated issues. Use this to add guardrails."
    echo ""
  } > "$ERRORS_LOG_PATH"
fi

if [ ! -f "$ACTIVITY_LOG_PATH" ]; then
  {
    echo "# Activity Log"
    echo ""
    echo "## Run Summary"
    echo ""
    echo "## Events"
    echo ""
  } > "$ACTIVITY_LOG_PATH"
fi

RUN_TAG="$(date +%Y%m%d-%H%M%S)-$$"

render_prompt() {
  local src="$1"
  local dst="$2"
  local story_meta="$3"
  local story_block="$4"
  local run_id="$5"
  local iter="$6"
  local run_log="$7"
  local run_meta="$8"
  python3 - "$src" "$dst" "$PRD_PATH" "$AGENTS_PATH" "$PROGRESS_PATH" "$ROOT_DIR" "$GUARDRAILS_PATH" "$ERRORS_LOG_PATH" "$ACTIVITY_LOG_PATH" "$GUARDRAILS_REF" "$CONTEXT_REF" "$ACTIVITY_CMD" "$NO_COMMIT" "$story_meta" "$story_block" "$run_id" "$iter" "$run_log" "$run_meta" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_text()
prd, agents, progress, root = sys.argv[3:7]
guardrails = sys.argv[7]
errors_log = sys.argv[8]
activity_log = sys.argv[9]
guardrails_ref = sys.argv[10]
context_ref = sys.argv[11]
activity_cmd = sys.argv[12]
no_commit = sys.argv[13]
meta_path = sys.argv[14] if len(sys.argv) > 14 else ""
block_path = sys.argv[15] if len(sys.argv) > 15 else ""
run_id = sys.argv[16] if len(sys.argv) > 16 else ""
iteration = sys.argv[17] if len(sys.argv) > 17 else ""
run_log = sys.argv[18] if len(sys.argv) > 18 else ""
run_meta = sys.argv[19] if len(sys.argv) > 19 else ""
repl = {
    "PRD_PATH": prd,
    "AGENTS_PATH": agents,
    "PROGRESS_PATH": progress,
    "REPO_ROOT": root,
    "GUARDRAILS_PATH": guardrails,
    "ERRORS_LOG_PATH": errors_log,
    "ACTIVITY_LOG_PATH": activity_log,
    "GUARDRAILS_REF": guardrails_ref,
    "CONTEXT_REF": context_ref,
    "ACTIVITY_CMD": activity_cmd,
    "NO_COMMIT": no_commit,
    "RUN_ID": run_id,
    "ITERATION": iteration,
    "RUN_LOG_PATH": run_log,
    "RUN_META_PATH": run_meta,
}
story = {"id": "", "title": "", "block": ""}
quality_gates = []
if meta_path:
    try:
        import json
        meta = json.loads(Path(meta_path).read_text())
        story["id"] = meta.get("id", "") or ""
        story["title"] = meta.get("title", "") or ""
        quality_gates = meta.get("quality_gates", []) or []
    except Exception:
        pass
if block_path and Path(block_path).exists():
    story["block"] = Path(block_path).read_text()
repl["STORY_ID"] = story["id"]
repl["STORY_TITLE"] = story["title"]
repl["STORY_BLOCK"] = story["block"]
if quality_gates:
    repl["QUALITY_GATES"] = "\n".join([f"- {g}" for g in quality_gates])
else:
    repl["QUALITY_GATES"] = "- (none)"
for k, v in repl.items():
    src = src.replace("{{" + k + "}}", v)
Path(sys.argv[2]).write_text(src)
PY
}

select_story() {
  local meta_out="$1"
  local block_out="$2"
  python3 - "$PRD_PATH" "$meta_out" "$block_out" "$STALE_SECONDS" <<'PY'
import json
import os
import sys
from pathlib import Path
from datetime import datetime, timezone
try:
    import fcntl
except Exception:
    fcntl = None

prd_path = Path(sys.argv[1])
meta_out = Path(sys.argv[2])
block_out = Path(sys.argv[3])
stale_seconds = 0
if len(sys.argv) > 4:
    try:
        stale_seconds = int(sys.argv[4])
    except Exception:
        stale_seconds = 0

if not prd_path.exists():
    meta_out.write_text(json.dumps({"ok": False, "error": "PRD not found"}, indent=2) + "\n")
    block_out.write_text("")
    sys.exit(0)

def normalize_status(value):
    if value is None:
        return "open"
    return str(value).strip().lower()

def parse_ts(value):
    if not value:
        return None
    text = str(value).strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        return datetime.fromisoformat(text)
    except Exception:
        return None

def now_iso():
    return datetime.now(timezone.utc).isoformat()

with prd_path.open("r+", encoding="utf-8") as fh:
    if fcntl is not None:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        try:
            data = json.load(fh)
        except Exception as exc:
            meta_out.write_text(json.dumps({"ok": False, "error": f"Invalid PRD JSON: {exc}"}, indent=2) + "\n")
            block_out.write_text("")
            sys.exit(0)

        stories = data.get("stories") if isinstance(data, dict) else None
        if not isinstance(stories, list) or not stories:
            meta_out.write_text(json.dumps({"ok": False, "error": "No stories found in PRD"}, indent=2) + "\n")
            block_out.write_text("")
            sys.exit(0)

        story_index = {s.get("id"): s for s in stories if isinstance(s, dict)}

        def is_done(story_id: str) -> bool:
            target = story_index.get(story_id)
            if not isinstance(target, dict):
                return False
            return normalize_status(target.get("status")) == "done"

        if stale_seconds > 0:
            now = datetime.now(timezone.utc)
            for story in stories:
                if not isinstance(story, dict):
                    continue
                if normalize_status(story.get("status")) != "in_progress":
                    continue
                started = parse_ts(story.get("startedAt"))
                if started is None or (now - started).total_seconds() > stale_seconds:
                    story["status"] = "open"
                    story["startedAt"] = None
                    story["completedAt"] = None
                    story["updatedAt"] = now_iso()

        candidate = None
        for story in stories:
            if not isinstance(story, dict):
                continue
            if normalize_status(story.get("status")) != "open":
                continue
            deps = story.get("dependsOn") or []
            if not isinstance(deps, list):
                deps = []
            if all(is_done(dep) for dep in deps):
                candidate = story
                break

        remaining = sum(
            1 for story in stories
            if isinstance(story, dict) and normalize_status(story.get("status")) != "done"
        )

        meta = {
            "ok": True,
            "total": len(stories),
            "remaining": remaining,
            "quality_gates": data.get("qualityGates", []) or [],
        }

        if candidate:
            candidate["status"] = "in_progress"
            if not candidate.get("startedAt"):
                candidate["startedAt"] = now_iso()
            candidate["completedAt"] = None
            candidate["updatedAt"] = now_iso()
            meta.update({
                "id": candidate.get("id", ""),
                "title": candidate.get("title", ""),
            })

            depends = candidate.get("dependsOn") or []
            if not isinstance(depends, list):
                depends = []
            acceptance = candidate.get("acceptanceCriteria") or []
            if not isinstance(acceptance, list):
                acceptance = []

            description = candidate.get("description") or ""
            block_lines = []
            block_lines.append(f"### {candidate.get('id', '')}: {candidate.get('title', '')}")
            block_lines.append(f"Status: {candidate.get('status', 'open')}")
            block_lines.append(
                f"Depends on: {', '.join(depends) if depends else 'None'}"
            )
            block_lines.append("")
            block_lines.append("Description:")
            block_lines.append(description if description else "(none)")
            block_lines.append("")
            block_lines.append("Acceptance Criteria:")
            if acceptance:
                block_lines.extend([f"- [ ] {item}" for item in acceptance])
            else:
                block_lines.append("- (none)")
            block_out.write_text("\n".join(block_lines).rstrip() + "\n")
        else:
            block_out.write_text("")

        fh.seek(0)
        fh.truncate()
        json.dump(data, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    finally:
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)

meta_out.write_text(json.dumps(meta, indent=2) + "\n")
PY
}

remaining_stories() {
  local meta_file="$1"
  python3 - "$meta_file" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
print(data.get("remaining", "unknown"))
PY
}

remaining_from_prd() {
  python3 - "$PRD_PATH" <<'PY'
import json
import sys
from pathlib import Path

prd_path = Path(sys.argv[1])
if not prd_path.exists():
    print("unknown")
    sys.exit(0)

try:
    data = json.loads(prd_path.read_text())
except Exception:
    print("unknown")
    sys.exit(0)

stories = data.get("stories") if isinstance(data, dict) else None
if not isinstance(stories, list):
    print("unknown")
    sys.exit(0)

def normalize_status(value):
    if value is None:
        return "open"
    return str(value).strip().lower()

remaining = sum(
    1 for story in stories
    if isinstance(story, dict) and normalize_status(story.get("status")) != "done"
)
print(remaining)
PY
}

story_field() {
  local meta_file="$1"
  local field="$2"
  python3 - "$meta_file" "$field" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text())
field = sys.argv[2]
print(data.get(field, ""))
PY
}

update_story_status() {
  local story_id="$1"
  local new_status="$2"
  python3 - "$PRD_PATH" "$story_id" "$new_status" <<'PY'
import json
import os
import sys
from pathlib import Path
from datetime import datetime, timezone
try:
    import fcntl
except Exception:
    fcntl = None

prd_path = Path(sys.argv[1])
story_id = sys.argv[2]
new_status = sys.argv[3]

if not story_id:
    sys.exit(0)

if not prd_path.exists():
    sys.exit(0)

def now_iso():
    return datetime.now(timezone.utc).isoformat()

with prd_path.open("r+", encoding="utf-8") as fh:
    if fcntl is not None:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
    try:
        data = json.load(fh)
        stories = data.get("stories") if isinstance(data, dict) else None
        if not isinstance(stories, list):
            sys.exit(0)
        for story in stories:
            if isinstance(story, dict) and story.get("id") == story_id:
                story["status"] = new_status
                story["updatedAt"] = now_iso()
                if new_status == "in_progress":
                    if not story.get("startedAt"):
                        story["startedAt"] = now_iso()
                    story["completedAt"] = None
                elif new_status == "done":
                    story["completedAt"] = now_iso()
                    if not story.get("startedAt"):
                        story["startedAt"] = now_iso()
                elif new_status == "open":
                    story["startedAt"] = None
                    story["completedAt"] = None
                break
        fh.seek(0)
        fh.truncate()
        json.dump(data, fh, indent=2)
        fh.write("\n")
        fh.flush()
        os.fsync(fh.fileno())
    finally:
        if fcntl is not None:
            fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
PY
}

log_activity() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $message" >> "$ACTIVITY_LOG_PATH"
}

log_error() {
  local message="$1"
  local timestamp
  timestamp=$(date '+%Y-%m-%d %H:%M:%S')
  echo "[$timestamp] $message" >> "$ERRORS_LOG_PATH"
}

append_run_summary() {
  local line="$1"
  python3 - "$ACTIVITY_LOG_PATH" "$line" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
line = sys.argv[2]
text = path.read_text().splitlines()
out = []
inserted = False
for l in text:
    out.append(l)
    if not inserted and l.strip() == "## Run Summary":
        out.append(f"- {line}")
        inserted = True
if not inserted:
    out = [
        "# Activity Log",
        "",
        "## Run Summary",
        f"- {line}",
        "",
        "## Events",
        "",
    ] + text
Path(path).write_text("\n".join(out).rstrip() + "\n")
PY
}

write_run_meta() {
  local path="$1"
  local mode="$2"
  local iter="$3"
  local run_id="$4"
  local story_id="$5"
  local story_title="$6"
  local started="$7"
  local ended="$8"
  local duration="$9"
  local status="${10}"
  local log_file="${11}"
  local head_before="${12}"
  local head_after="${13}"
  local commit_list="${14}"
  local changed_files="${15}"
  local dirty_files="${16}"
  {
    echo "# Ralph Run Summary"
    echo ""
    echo "- Run ID: $run_id"
    echo "- Iteration: $iter"
    echo "- Mode: $mode"
    if [ -n "$story_id" ]; then
      echo "- Story: $story_id: $story_title"
    fi
    echo "- Started: $started"
    echo "- Ended: $ended"
    echo "- Duration: ${duration}s"
    echo "- Status: $status"
    echo "- Log: $log_file"
    echo ""
    echo "## Git"
    echo "- Head (before): ${head_before:-unknown}"
    echo "- Head (after): ${head_after:-unknown}"
    echo ""
    echo "### Commits"
    if [ -n "$commit_list" ]; then
      echo "$commit_list"
    else
      echo "- (none)"
    fi
    echo ""
    echo "### Changed Files (commits)"
    if [ -n "$changed_files" ]; then
      echo "$changed_files"
    else
      echo "- (none)"
    fi
    echo ""
    echo "### Uncommitted Changes"
    if [ -n "$dirty_files" ]; then
      echo "$dirty_files"
    else
      echo "- (clean)"
    fi
    echo ""
  } > "$path"
}

git_head() {
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true
  else
    echo ""
  fi
}

git_commit_list() {
  local before="$1"
  local after="$2"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    git -C "$ROOT_DIR" log --oneline "$before..$after" | sed 's/^/- /'
  else
    echo ""
  fi
}

git_changed_files() {
  local before="$1"
  local after="$2"
  if [ -n "$before" ] && [ -n "$after" ] && [ "$before" != "$after" ]; then
    git -C "$ROOT_DIR" diff --name-only "$before" "$after" | sed 's/^/- /'
  else
    echo ""
  fi
}

git_dirty_files() {
  if git -C "$ROOT_DIR" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$ROOT_DIR" status --porcelain | awk '{print "- " $2}'
  else
    echo ""
  fi
}

echo "Ralph mode: $MODE"
echo "Max iterations: $MAX_ITERATIONS"
echo "PRD: $PRD_PATH"
# Detect and display agent info
AGENT_BIN="${AGENT_CMD%% *}"
AGENT_DISPLAY="$AGENT_BIN"
if [[ "$AGENT_CMD" == *"zai-settings.json"* ]]; then
  AGENT_DISPLAY="$AGENT_BIN (glm via z.ai settings)"
elif [[ "$AGENT_CMD" == *"--settings"* ]]; then
  SETTINGS_FILE=$(echo "$AGENT_CMD" | sed -n 's/.*--settings \([^ ]*\).*/\1/p')
  AGENT_DISPLAY="$AGENT_BIN (custom: $SETTINGS_FILE)"
fi
echo "Agent: $AGENT_DISPLAY"
HAS_ERROR="false"
MAX_RETRIES=3  # Max retries for "No messages returned" errors
RETRY_COUNT=0  # Initialize retry counter outside the loop

i=1
while [ $i -le $MAX_ITERATIONS ]; do
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  Ralph Iteration $i of $MAX_ITERATIONS"
  echo "═══════════════════════════════════════════════════════"

  HAS_CRITICAL_ERROR=false
  STORY_META=""
  STORY_BLOCK=""
  ITER_START=$(date +%s)
  ITER_START_FMT=$(date '+%Y-%m-%d %H:%M:%S')
  if [ "$MODE" = "build" ]; then
    STORY_META="$TMP_DIR/story-$RUN_TAG-$i.json"
    STORY_BLOCK="$TMP_DIR/story-$RUN_TAG-$i.md"
    select_story "$STORY_META" "$STORY_BLOCK"
    REMAINING="$(remaining_stories "$STORY_META")"
    if [ "$REMAINING" = "unknown" ]; then
      echo "Could not parse stories from PRD: $PRD_PATH"
      exit 1
    fi
    if [ "$REMAINING" = "0" ]; then
      echo "No remaining stories."
      exit 0
    fi
    STORY_ID="$(story_field "$STORY_META" "id")"
    STORY_TITLE="$(story_field "$STORY_META" "title")"
    if [ -z "$STORY_ID" ]; then
      echo "No actionable open stories (all blocked or in progress). Remaining: $REMAINING"
      exit 0
    fi
  fi

  HEAD_BEFORE="$(git_head)"
  PROMPT_RENDERED="$TMP_DIR/prompt-$RUN_TAG-$i.md"
  LOG_FILE="$RUNS_DIR/run-$RUN_TAG-iter-$i.log"
  RUN_META="$RUNS_DIR/run-$RUN_TAG-iter-$i.md"
  render_prompt "$PROMPT_FILE" "$PROMPT_RENDERED" "$STORY_META" "$STORY_BLOCK" "$RUN_TAG" "$i" "$LOG_FILE" "$RUN_META"

  if [ "$MODE" = "build" ] && [ -n "${STORY_ID:-}" ]; then
    log_activity "ITERATION $i start (mode=$MODE story=$STORY_ID)"
  else
    log_activity "ITERATION $i start (mode=$MODE)"
  fi
  set +e
  if [ "${RALPH_DRY_RUN:-}" = "1" ]; then
    echo "[RALPH_DRY_RUN] Skipping agent execution." | tee "$LOG_FILE"
    CMD_STATUS=0
  else
    run_agent "$PROMPT_RENDERED" 2>&1 | tee "$LOG_FILE"
    CMD_STATUS=$?
  fi
  set -e
  if [ "$CMD_STATUS" -eq 130 ] || [ "$CMD_STATUS" -eq 143 ]; then
    echo "Interrupted."
    exit "$CMD_STATUS"
  fi
  ITER_END=$(date +%s)
  ITER_END_FMT=$(date '+%Y-%m-%d %H:%M:%S')
  ITER_DURATION=$((ITER_END - ITER_START))
  HEAD_AFTER="$(git_head)"
  log_activity "ITERATION $i end (duration=${ITER_DURATION}s)"
  if [ "$CMD_STATUS" -ne 0 ]; then
    log_error "ITERATION $i command failed (status=$CMD_STATUS)"
    HAS_ERROR="true"
  fi
  COMMIT_LIST="$(git_commit_list "$HEAD_BEFORE" "$HEAD_AFTER")"
  CHANGED_FILES="$(git_changed_files "$HEAD_BEFORE" "$HEAD_AFTER")"
  DIRTY_FILES="$(git_dirty_files)"
  STATUS_LABEL="success"
  if [ "$CMD_STATUS" -ne 0 ]; then
    STATUS_LABEL="error"
  fi
  if [ "$MODE" = "build" ] && [ "$NO_COMMIT" = "false" ] && [ -n "$DIRTY_FILES" ]; then
    log_error "ITERATION $i left uncommitted changes; review run summary at $RUN_META"
  fi
  write_run_meta "$RUN_META" "$MODE" "$i" "$RUN_TAG" "${STORY_ID:-}" "${STORY_TITLE:-}" "$ITER_START_FMT" "$ITER_END_FMT" "$ITER_DURATION" "$STATUS_LABEL" "$LOG_FILE" "$HEAD_BEFORE" "$HEAD_AFTER" "$COMMIT_LIST" "$CHANGED_FILES" "$DIRTY_FILES"
  if [ "$MODE" = "build" ] && [ -n "${STORY_ID:-}" ]; then
    append_run_summary "$(date '+%Y-%m-%d %H:%M:%S') | run=$RUN_TAG | iter=$i | mode=$MODE | story=$STORY_ID | duration=${ITER_DURATION}s | status=$STATUS_LABEL"
  else
    append_run_summary "$(date '+%Y-%m-%d %H:%M:%S') | run=$RUN_TAG | iter=$i | mode=$MODE | duration=${ITER_DURATION}s | status=$STATUS_LABEL"
  fi

  if [ "$MODE" = "build" ]; then
    # Check for critical errors in the log that indicate failure, even if exit code was 0
    HAS_CRITICAL_ERROR=false
    if grep -qiE "No messages returned" "$LOG_FILE"; then
      log_error "ITERATION $i: 'No messages returned' error in log; agent may not have produced valid output"
      HAS_CRITICAL_ERROR=true
    fi

    if [ "$CMD_STATUS" -ne 0 ]; then
      log_error "ITERATION $i exited non-zero; review $LOG_FILE"
      update_story_status "$STORY_ID" "open"
      echo "Iteration failed; story reset to open."
    elif [ "$HAS_CRITICAL_ERROR" = "true" ]; then
      log_error "ITERATION $i had critical error in log; review $LOG_FILE"
      update_story_status "$STORY_ID" "open"
      echo "Iteration had critical error; story reset to open."
    else
      # Check for completion signal with robust pattern matching
      # Signal must be on its own line, but we allow for:
      # - Leading/trailing whitespace
      # - Case variations (COMPLETE, complete, Complete)
      # - Minor formatting differences (spaces within tags)
      COMPLETE_SIGNAL=""
      COMPLETE_SIGNAL=$(grep -iE '^\s*<promise>\s*COMPLETE\s*</promise>\s*$' "$LOG_FILE" || true)

      if [ -n "$COMPLETE_SIGNAL" ]; then
        update_story_status "$STORY_ID" "done"
        echo "Completion signal received; story marked done."
        echo "  Signal found: $COMPLETE_SIGNAL"
      else
        # Try additional pattern checks for debugging
        if grep -qi "promise.*complete" "$LOG_FILE"; then
          echo "Warning: Completion signal found but not in expected format."
          echo "  Signal must be on its own line as: <promise>COMPLETE</promise>"
          log_error "ITERATION $i: Malformed completion signal in $LOG_FILE"
        fi
        update_story_status "$STORY_ID" "open"
        echo "No valid completion signal; story reset to open."
      fi
    fi
    REMAINING="$(remaining_from_prd)"
    echo "Iteration $i complete. Remaining stories: $REMAINING"
    if [ "$REMAINING" = "0" ]; then
      echo "No remaining stories."
      exit 0
    fi
  else
    echo "Iteration $i complete."
  fi

  # Check for "No messages returned" error and retry
  if [ "$MODE" = "build" ] && [ "$HAS_CRITICAL_ERROR" = "true" ] && [ $RETRY_COUNT -lt $MAX_RETRIES ]; then
    if grep -qiE "No messages returned" "$LOG_FILE"; then
      RETRY_COUNT=$((RETRY_COUNT + 1))
      echo "[Ralph] 'No messages returned' detected. Retrying iteration $i (attempt $RETRY_COUNT/$MAX_RETRIES)..."
      log_error "ITERATION $i: 'No messages returned' - retrying (attempt $RETRY_COUNT/$MAX_RETRIES)"

      # Clear Claude conversation state to force fresh start
      local claude_dir="$HOME/.claude"
      local conversations_dir="$claude_dir/conversations"
      if [ -d "$conversations_dir" ]; then
        local latest_conv
        latest_conv="$(find "$conversations_dir" -type f -name "*.json" -print0 2>/dev/null | xargs -0 ls -t 2>/dev/null | head -1)"
        if [ -n "$latest_conv" ]; then
          echo "[Ralph] Removing latest conversation: $latest_conv"
          rm -f "$latest_conv"
        fi
      fi

      # Retry the same iteration (don't increment i)
      sleep 2
      continue
    fi
  fi

  # Move to next iteration
  RETRY_COUNT=0  # Reset retry counter for next iteration
  i=$((i + 1))
  sleep 2

done

echo "Reached max iterations ($MAX_ITERATIONS)."
if [ "$HAS_ERROR" = "true" ]; then
  exit 1
fi
exit 0
