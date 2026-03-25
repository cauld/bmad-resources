#!/usr/bin/env bash
#
# BMAD AutoDev Pipeline
# Author: Chad Auld (https://github.com/cauld)
# Repo:   https://github.com/cauld/bmad-resources
# License: MIT (https://opensource.org/licenses/MIT)
#
set -euo pipefail

# ⚠️  SECURITY NOTICE
#
# This pipeline runs automated Claude Code sessions with --dangerously-skip-permissions.
# The agents have access to board tools and auto-accept changes without explicit confirmation.
#
# STRONGLY RECOMMENDED: Run this script inside a Dev Container or Docker container to
# isolate it from your host system. This prevents any unintended modifications from
# affecting your local environment, dependencies, or sensitive files.
#
# Dev Container setup: https://containers.dev/
# Docker: docker run -it -v $(pwd):/workspace node:20 /bin/bash
#
# TODO: Spike on replacing --dangerously-skip-permissions with --allowedTools for
# per-step least-privilege permissions. E.g.:
#   Steps 1-5: "Read Edit Write Glob Grep Task(Explore)"  (file ops only)
#   Step 6:    "Read Edit Glob Grep"                      (minimal)
#   Step 7:    "Read Edit Write Glob Grep Bash(npm run *) Bash(cargo *) Bash(./scripts/*)"
#
# ────────────────────────────────────────────────────────────────────────────────────

# Dev Story Pipeline
#
# Automates the full BMAD development workflow with per-step model switching.
# Each step runs a separate Claude Code session via `claude -p`.
#
# Pipeline Flow:
#
#   ┌─────────────────────────────────────────────────────────────────┐
#   │                     Dev Story Pipeline                         │
#   └─────────────────────────────────────────────────────────────────┘
#
#   ┌───────────────────┐
#   │  1. Implement     │  MODEL_DEV
#   │     Story         │  Run dev-story workflow, write code + tests
#   └────────┬──────────┘
#            │
#            ▼
#   ┌───────────────────┐
#   │  2. Code Review   │  MODEL_REVIEW
#   │                   │  Adversarial code review → $CODE_REVIEW_DIR/
#   └────────┬──────────┘
#            │
#            ▼
#   ┌───────────────────┐
#   │  3. Fix Code      │  MODEL_FIX
#   │     Review        │  Address all code review findings
#   └────────┬──────────┘
#            │
#            ▼
#   ┌───────────────────┐
#   │  4. Test Review   │  MODEL_REVIEW
#   │                   │  Test quality review → $TEST_REVIEW_FILE
#   └────────┬──────────┘
#            │
#            ▼
#   ┌───────────────────┐
#   │  5. Fix Test      │  MODEL_FIX
#   │     Review        │  Address all test review findings
#   └────────┬──────────┘
#            │
#            ▼
#   ┌───────────────────┐
#   │  6. Mark Story    │  MODEL_SPRINT
#   │     Done          │  Update sprint-status.yaml
#   └────────┬──────────┘
#            │
#            ▼
#   ┌───────────────────┐
#   │  7. Lint &        │  MODEL_FIX
#   │     Pre-Release   │  $LINT_CMD, $PRERELEASE_CMD
#   └────────┬──────────┘
#            │
#            ▼
#        ✅ Done
#
# Usage:
#   ./scripts/bmad-autodev.sh [options]
#
# Options:
#   --story <id|file>      Story ID (e.g. 34-4 or 34.4) or full path
#   --epic [N]             Run all ready-for-dev stories in epic N (or auto-detect first epic)
#   --skip-dev             Skip step 1 (story implementation) — useful for re-running reviews
#   --start-at <N>         Start at step N (1-7), skipping earlier steps
#   --stop-at <N>          Stop after step N (1-7) — e.g. --start-at 2 --stop-at 3
#   --verbose              Stream tool activity (file edits, commands) in real time
#   --quiet                Show only step headers and progress bar (suppress LLM output)
#   --dry-run              Show what would run without executing
#   --help                 Show this help message
#
# Model overrides (environment variables):
#   MODEL_DEV=sonnet       Model for story implementation (default: sonnet)
#   MODEL_REVIEW=opus      Model for code/test reviews (default: opus)
#   MODEL_FIX=sonnet       Model for addressing findings & fixes (default: sonnet)
#   MODEL_SPRINT=haiku     Model for sprint status updates (default: haiku)
#
# Examples:
#   ./scripts/bmad-autodev.sh --story 34.4
#   ./scripts/bmad-autodev.sh --story 35-1
#   ./scripts/bmad-autodev.sh --story _bmad-output/implementation-artifacts/35-1-feature.md
#   ./scripts/bmad-autodev.sh --epic 1              # run all ready-for-dev stories in epic 1
#   ./scripts/bmad-autodev.sh --epic                # auto-detect first epic with ready stories
#   ./scripts/bmad-autodev.sh --start-at 2 --stop-at 3   # code review cycle only
#   MODEL_FIX=haiku ./scripts/bmad-autodev.sh --start-at 3
#   ./scripts/bmad-autodev.sh --dry-run
#   ./scripts/bmad-autodev.sh --quiet --story 35-1

# Allow running from VS Code terminal while Claude Code is active
unset CLAUDECODE 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
DIM='\033[2m'
NC='\033[0m'

# Temp directory for all pipeline scratch files (cleaned up on exit)
TMPDIR_PIPELINE=$(mktemp -d /tmp/claude-pipeline.XXXXXX)

cleanup() {
    rm -rf "$TMPDIR_PIPELINE"
}

on_interrupt() {
    echo ""
    echo -e "${RED}  Pipeline interrupted.${NC}"
    if [ -d "${LOG_DIR:-}" ]; then
        echo -e "${DIM}  Logs saved to: $LOG_DIR${NC}"
    fi
    cleanup
    exit 130
}

trap cleanup EXIT
trap on_interrupt INT TERM

# Configurable models (override via env vars)
MODEL_DEV="${MODEL_DEV:-sonnet}"
MODEL_REVIEW="${MODEL_REVIEW:-opus}"
MODEL_FIX="${MODEL_FIX:-sonnet}"
MODEL_SPRINT="${MODEL_SPRINT:-haiku}"

# Project-specific configuration (override via env vars)
# Defaults match BMAD standard directory layout
STORIES_DIR="${STORIES_DIR:-_bmad-output/implementation-artifacts}"
# CODE_REVIEW_DIR and TEST_REVIEW_FILE are co-located by default.
# If you override one, override both to keep them consistent.
CODE_REVIEW_DIR="${CODE_REVIEW_DIR:-_bmad-output/test-artifacts}"
TEST_REVIEW_FILE="${TEST_REVIEW_FILE:-_bmad-output/test-artifacts/test-review.md}"
SPRINT_STATUS_FILE="${SPRINT_STATUS_FILE:-_bmad-output/implementation-artifacts/sprint-status.yaml}"

# BMAD workflow command names (override if using different workflow names)
WORKFLOW_DEV="${WORKFLOW_DEV:-*dev-story workflow}"
WORKFLOW_CODE_REVIEW="${WORKFLOW_CODE_REVIEW:-*code-review workflow}"
WORKFLOW_TEST_REVIEW="${WORKFLOW_TEST_REVIEW:-*testarch-test-review workflow}"

# Final checks (step 7) — set to empty string to skip either
LINT_CMD="${LINT_CMD:-}"
#
# PRERELEASE_CMD: the script that must pass before a story is accepted.
# It should run ALL checks required for story acceptance: unit tests, integration
# tests, type-checking, linting, and any other quality gates. The pipeline will
# keep iterating (fix → re-run) until this command exits 0.
#
# Set to empty string to skip step 7 entirely (not recommended for production use).
# If the script does not exist at startup, the pipeline will warn and abort.
PRERELEASE_CMD="${PRERELEASE_CMD:-./scripts/pre-release-check.sh}"

# Options
STORY_FILE=""
EPIC_NUM=""
DRY_RUN=false
VERBOSE=false
QUIET=false
START_AT=1
STOP_AT=7

usage() {
    echo "Usage: $0 [options]"
    echo ""
    echo "Automates the full BMAD dev-story pipeline with model switching."
    echo ""
    echo "Options:"
    echo "  --story <id|file> Story ID (e.g. 34-4, 34.4) or full path"
    echo "  --epic [N]        Run all ready-for-dev stories in epic N (auto-detects if omitted)"
    echo "  --skip-dev        Skip step 1 (story implementation)"
    echo "  --start-at <N>    Start at step N (1-7)"
    echo "  --stop-at <N>     Stop after step N (1-7)"
    echo "  --verbose         Stream tool activity in real time"
    echo "  --quiet           Show only step headers and progress bar (suppress LLM output)"
    echo "  --dry-run         Preview commands without executing"
    echo "  --help            Show this help"
    echo ""
    echo "Model overrides (env vars):"
    echo "  MODEL_DEV=$MODEL_DEV  MODEL_REVIEW=$MODEL_REVIEW  MODEL_FIX=$MODEL_FIX  MODEL_SPRINT=$MODEL_SPRINT"
    echo ""
    echo "Project configuration (env vars):"
    echo "  STORIES_DIR=$STORIES_DIR"
    echo "  CODE_REVIEW_DIR=$CODE_REVIEW_DIR"
    echo "  TEST_REVIEW_FILE=$TEST_REVIEW_FILE"
    echo "  SPRINT_STATUS_FILE=$SPRINT_STATUS_FILE"
    echo "  WORKFLOW_DEV=$WORKFLOW_DEV"
    echo "  WORKFLOW_CODE_REVIEW=$WORKFLOW_CODE_REVIEW"
    echo "  WORKFLOW_TEST_REVIEW=$WORKFLOW_TEST_REVIEW"
    echo "  LINT_CMD=${LINT_CMD:-(not set)}"
    echo "  PRERELEASE_CMD=${PRERELEASE_CMD:-(not set)}"
    exit 0
}

# Resolve a story ID (e.g. "34-4" or "34.4") to a full file path.
# If the input is already a path (contains / or ends in .md), it's used as-is.
resolve_story() {
    local input="$1"

    # Already a path — use as-is
    if [[ "$input" == */* || "$input" == *.md ]]; then
        if [ ! -f "$PROJECT_ROOT/$input" ] && [ ! -f "$input" ]; then
            echo -e "${RED}Story file not found: $input${NC}" >&2
            exit 1
        fi
        echo "$input"
        return
    fi

    # Normalize dots to dashes: 34.4 → 34-4
    local prefix="${input//./-}"

    # Search for matching files: exact match first, then prefix match
    local matches=()
    # Check for exact match: <prefix>.md
    if [ -f "$PROJECT_ROOT/$STORIES_DIR/${prefix}.md" ]; then
        matches+=("$PROJECT_ROOT/$STORIES_DIR/${prefix}.md")
    fi
    # Also check for prefix match: <prefix>-*.md
    while IFS= read -r -d '' f; do
        matches+=("$f")
    done < <(find "$PROJECT_ROOT/$STORIES_DIR" -maxdepth 1 -name "${prefix}-*.md" -print0 2>/dev/null)

    if [ ${#matches[@]} -eq 0 ]; then
        echo -e "${RED}No story found matching '${prefix}' or '${prefix}-*' in $STORIES_DIR/${NC}" >&2
        exit 1
    elif [ ${#matches[@]} -eq 1 ]; then
        # Make path relative to project root
        echo "${matches[0]#"$PROJECT_ROOT/"}"
        return
    else
        echo -e "${YELLOW}Multiple stories match '${prefix}':${NC}" >&2
        local i=1
        for f in "${matches[@]}"; do
            echo -e "  $i) $(basename "$f")" >&2
            ((i++))
        done
        echo -en "${YELLOW}Pick one [1-${#matches[@]}]: ${NC}" >&2
        read -r choice
        if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le ${#matches[@]} ]; then
            echo "${matches[$((choice-1))]#"$PROJECT_ROOT/"}"
            return
        else
            echo -e "${RED}Invalid choice. Aborting.${NC}" >&2
            exit 1
        fi
    fi
}

# Find the next ready-for-dev story ID in an epic from sprint-status.yaml.
# Returns the story key (e.g. "1-2-account-management") or empty string if none found.
find_next_story_in_epic() {
    local epic_num="$1"
    local status_file="$PROJECT_ROOT/$SPRINT_STATUS_FILE"

    if [ ! -f "$status_file" ]; then
        echo -e "${RED}Sprint status file not found: $SPRINT_STATUS_FILE${NC}" >&2
        echo -e "${RED}Run sprint planning first to generate it.${NC}" >&2
        return 1
    fi

    # Find lines matching "<epic_num>-<rest>: ready-for-dev" in the status file
    # The story key is everything before the colon
    grep -E "^\s+${epic_num}-[^:]+:\s*ready-for-dev" "$status_file" \
        | head -1 \
        | sed 's/^[[:space:]]*//' \
        | cut -d: -f1 \
        || true
}

# Find the first epic number that has any ready-for-dev stories.
find_first_epic_with_ready_stories() {
    local status_file="$PROJECT_ROOT/$SPRINT_STATUS_FILE"

    if [ ! -f "$status_file" ]; then
        echo -e "${RED}Sprint status file not found: $SPRINT_STATUS_FILE${NC}" >&2
        echo -e "${RED}Run sprint planning first to generate it.${NC}" >&2
        return 1
    fi

    # Find the first ready-for-dev story line, extract its epic number (first digit group)
    grep -E "^\s+[0-9]+-[^:]+:\s*ready-for-dev" "$status_file" \
        | head -1 \
        | sed 's/^[[:space:]]*//' \
        | grep -oE '^[0-9]+' \
        || true
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --story)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo -e "${RED}--story requires a value (story ID or file path)${NC}"
                exit 1
            fi
            STORY_FILE="$2"
            shift 2
            ;;
        --epic)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                # No epic number given — will auto-detect later
                EPIC_NUM="auto"
                shift
            elif ! [[ "$2" =~ ^[0-9]+$ ]]; then
                echo -e "${RED}--epic must be a number (got: $2)${NC}"
                exit 1
            else
                EPIC_NUM="$2"
                shift 2
            fi
            ;;
        --skip-dev)
            START_AT=2
            shift
            ;;
        --start-at)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo -e "${RED}--start-at requires a step number (1-7)${NC}"
                exit 1
            fi
            if ! [[ "$2" =~ ^[1-7]$ ]]; then
                echo -e "${RED}--start-at must be 1-7 (got: $2)${NC}"
                exit 1
            fi
            START_AT="$2"
            shift 2
            ;;
        --stop-at)
            if [[ -z "${2:-}" || "$2" == --* ]]; then
                echo -e "${RED}--stop-at requires a step number (1-7)${NC}"
                exit 1
            fi
            if ! [[ "$2" =~ ^[1-7]$ ]]; then
                echo -e "${RED}--stop-at must be 1-7 (got: $2)${NC}"
                exit 1
            fi
            STOP_AT="$2"
            shift 2
            ;;
        --verbose)
            VERBOSE=true
            shift
            ;;
        --quiet)
            QUIET=true
            shift
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --help|-h)
            usage
            ;;
        *)
            echo -e "${RED}Unknown option: $1${NC}"
            usage
            ;;
    esac
done

# Validate --start-at / --stop-at range
if [ "$STOP_AT" -lt "$START_AT" ]; then
    echo -e "${RED}--stop-at ($STOP_AT) must be >= --start-at ($START_AT)${NC}"
    exit 1
fi

# --quiet and --verbose are mutually exclusive
if [ "$QUIET" = true ] && [ "$VERBOSE" = true ]; then
    echo -e "${RED}--quiet and --verbose are mutually exclusive${NC}"
    exit 1
fi

# --story and --epic are mutually exclusive
if [ -n "$STORY_FILE" ] && [ -n "$EPIC_NUM" ]; then
    echo -e "${RED}--story and --epic are mutually exclusive${NC}"
    exit 1
fi

# Validate PRERELEASE_CMD script exists if set
if [ -n "$PRERELEASE_CMD" ] && [ "$START_AT" -le 7 ] && [ "$STOP_AT" -ge 7 ]; then
    # Extract the script path (first token of the command)
    _prerelease_script="${PRERELEASE_CMD%% *}"
    if [ ! -f "$PROJECT_ROOT/$_prerelease_script" ] && [ ! -f "$_prerelease_script" ]; then
        echo -e "${RED}Pre-release script not found: $_prerelease_script${NC}"
        echo -e "${RED}Set PRERELEASE_CMD='' to skip step 7, or fix the path.${NC}"
        echo -e "${YELLOW}Tip: PRERELEASE_CMD should run all tests, type-checks, and quality gates${NC}"
        echo -e "${YELLOW}     required for story acceptance (e.g. ./scripts/pre-release-check.sh).${NC}"
        exit 1
    fi
fi

# --- Resolve Story File ---
if [ -n "$STORY_FILE" ]; then
    STORY_FILE=$(resolve_story "$STORY_FILE")
    echo -e "  Story: ${CYAN}$STORY_FILE${NC}"
elif [ -n "$EPIC_NUM" ]; then
    # Auto-detect epic if no number was given
    if [ "$EPIC_NUM" = "auto" ]; then
        EPIC_NUM=$(find_first_epic_with_ready_stories)
        if [ -z "$EPIC_NUM" ]; then
            echo -e "${YELLOW}No epics with ready-for-dev stories found in $SPRINT_STATUS_FILE.${NC}"
            exit 0
        fi
        echo -e "  Auto-detected epic: ${CYAN}$EPIC_NUM${NC}"
    fi
    echo -e "  Epic: ${CYAN}$EPIC_NUM${NC} (will find ready-for-dev stories from $SPRINT_STATUS_FILE)"
fi

# --- Preflight Check ---
if [ "$DRY_RUN" != true ]; then
    echo -e "${DIM}  Preflight: testing claude -p --dangerously-skip-permissions ...${NC}"
    preflight_out=$(claude -p --model haiku --dangerously-skip-permissions "Reply with only: PREFLIGHT_OK" 2>&1) || true
    if [[ "$preflight_out" == *"PREFLIGHT_OK"* ]]; then
        echo -e "${GREEN}  Preflight passed${NC}"
    else
        echo -e "${RED}  Preflight FAILED. Full output:${NC}"
        echo "$preflight_out"
        echo -e "${RED}  Aborting pipeline.${NC}"
        exit 1
    fi
fi

# --- Helpers ---

TOTAL_STEPS=7
COMPLETED_STEPS=0
PIPELINE_START=$SECONDS

# Per-step log directory
LOG_DIR="$PROJECT_ROOT/.pipeline-logs/$(date +%Y%m%d-%H%M%S)"
PIPELINE_LOG="$LOG_DIR/pipeline.log"
mkdir -p "$LOG_DIR"
echo -e "  Logs: ${DIM}$LOG_DIR${NC}"
echo -e "  ${DIM}tail -f $PIPELINE_LOG${NC}"

# Build progress bar: ████░░░░ 3/7
progress_bar() {
    local current=$1
    local total=$2
    local width=28
    local filled=$(( (current * width) / total ))
    local empty=$(( width - filled ))
    local bar=""
    for ((i=0; i<filled; i++)); do bar+="█"; done
    for ((i=0; i<empty; i++)); do bar+="░"; done
    echo "$bar"
}

step_header() {
    local step_num=$1
    local model=$2
    local description=$3
    local bar
    bar=$(progress_bar "$COMPLETED_STEPS" "$TOTAL_STEPS")
    echo ""
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
    echo -e "${BLUE}  Step $step_num/$TOTAL_STEPS: $description${NC}"
    echo -e "${DIM}  Model: $model${NC}"
    echo -e "${CYAN}  ${bar} ${COMPLETED_STEPS}/${TOTAL_STEPS} complete${NC}"
    echo -e "${BLUE}══════════════════════════════════════════════════════════${NC}"
}

step_done() {
    local step_num=$1
    local description=$2
    ((COMPLETED_STEPS++))
    echo -e "${GREEN}  ✓ Step $step_num/$TOTAL_STEPS complete: $description${NC}"
}

run_claude() {
    local step_num=$1
    local model=$2
    shift 2
    local prompt="$*"
    local step_log="$LOG_DIR/step-${step_num}.log"

    if [ "$DRY_RUN" = true ]; then
        echo -e "${YELLOW}  [DRY RUN] claude -p --model $model${NC}"
        echo -e "${DIM}  Prompt: ${prompt:0:120}...${NC}"
        return 0
    fi

    cd "$PROJECT_ROOT"

    local exit_code=0
    local exit_code_file="$TMPDIR_PIPELINE/exit-code-${step_num}.tmp"
    local stderr_log="$TMPDIR_PIPELINE/stderr-step.log"
    local start_time=$SECONDS
    local show_tools="$VERBOSE"
    local show_output
    show_output=$([[ "$QUIET" == true ]] && echo false || echo true)
    local pipeline_pid=""

    # Override the outer trap so Ctrl+C kills the running pipeline subshell
    # immediately, then falls through to on_interrupt for cleanup + exit.
    local_interrupt() {
        if [ -n "$pipeline_pid" ]; then
            kill "$pipeline_pid" 2>/dev/null || true
            wait "$pipeline_pid" 2>/dev/null || true
        fi
        on_interrupt
    }
    trap local_interrupt INT TERM

    echo -e "${CYAN}  Running: claude -p --model $model ...${NC}"
    echo ""

    # Run the pipeline in a background subshell so that 'wait' (a bash builtin)
    # is used instead of a foreground command.  This is critical: bash traps fire
    # immediately when 'wait' is interrupted, but only AFTER a foreground command
    # completes.  Without this, Ctrl+C appears to do nothing until claude exits.
    #
    # Non-interactive shells set SIGINT to SIG_IGN for background jobs by default;
    # 'trap - INT TERM' inside the subshell restores default signal handling so
    # that claude/python3/tee respond normally to Ctrl+C.
    #
    # We write PIPESTATUS[0] (claude's exit code) to a temp file because
    # PIPESTATUS is not available across the process boundary.
    set +o pipefail
    (
        trap - INT TERM
        claude -p --model "$model" --dangerously-skip-permissions \
            --verbose --output-format stream-json --include-partial-messages \
            "$prompt" 2>"$stderr_log" | \
        SHOW_TOOLS="$show_tools" SHOW_OUTPUT="$show_output" python3 -u -c "
import sys, json, os

show_tools = os.environ.get('SHOW_TOOLS', 'false') == 'true'
show_output = os.environ.get('SHOW_OUTPUT', 'true') == 'true'
DIM = '\033[2m'
RESET = '\033[0m'

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        d = json.loads(line)
    except (json.JSONDecodeError, ValueError):
        continue

    msg_type = d.get('type', '')

    if msg_type == 'assistant':
        for block in d.get('message', {}).get('content', []):
            bt = block.get('type', '')
            if bt == 'text' and show_output:
                text = block.get('text', '')
                if text:
                    print(text, end='', flush=True)
            elif bt == 'tool_use' and show_tools:
                name = block.get('name', '')
                inp = block.get('input', {})
                if name == 'Bash':
                    print(f'\n  {DIM}> {inp.get(\"command\", \"\")[:120]}{RESET}', flush=True)
                elif name in ('Read', 'Write', 'Edit'):
                    print(f'\n  {DIM}> {name}: {inp.get(\"file_path\", \"\")}{RESET}', flush=True)
                elif name in ('Glob', 'Grep'):
                    print(f'\n  {DIM}> {name}: {inp.get(\"pattern\", \"\")}{RESET}', flush=True)
                else:
                    print(f'\n  {DIM}> {name}{RESET}', flush=True)

    elif msg_type == 'content_block_delta' and show_output:
        # Partial text streaming (from --include-partial-messages)
        delta = d.get('delta', {})
        if delta.get('type') == 'text_delta':
            print(delta.get('text', ''), end='', flush=True)

    elif msg_type == 'result' and show_output:
        result_text = d.get('result', '')
        if result_text:
            print(result_text, flush=True)

print()  # final newline
" | tee "$step_log" | tee -a "$PIPELINE_LOG"
        echo "${PIPESTATUS[0]}" > "$exit_code_file"
    ) &
    pipeline_pid=$!
    set -o pipefail

    # 'wait' returns immediately when the INT trap fires (unlike foreground cmds)
    wait "$pipeline_pid" || true

    # Restore the outer trap now that the pipeline has finished
    trap on_interrupt INT TERM

    exit_code=$(cat "$exit_code_file" 2>/dev/null || echo "1")

    local elapsed=$(( SECONDS - start_time ))
    echo -e "${DIM}  Completed in ${elapsed}s (exit code: $exit_code)${NC}"
    echo -e "${DIM}  Log: $step_log${NC}"

    # Show stderr if anything was captured
    if [ -s "$stderr_log" ]; then
        echo -e "${RED}  stderr output:${NC}"
        cat "$stderr_log"
    fi

    if [ $exit_code -ne 0 ]; then
        echo -e "${RED}  Claude exited with code $exit_code${NC}"
        echo -e "${YELLOW}  Continue to next step? [y/N]${NC}"
        read -r answer
        if [[ ! "$answer" =~ ^[Yy] ]]; then
            echo -e "${RED}Pipeline aborted at step.${NC}"
            exit 1
        fi
    fi

    return 0
}

# --- Pipeline ---

echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║          Dev Story Pipeline                            ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  Models: dev=${CYAN}$MODEL_DEV${NC}  review=${CYAN}$MODEL_REVIEW${NC}  fix=${CYAN}$MODEL_FIX${NC}  sprint=${CYAN}$MODEL_SPRINT${NC}"
echo -e "  Steps: ${CYAN}$START_AT${NC} → ${CYAN}$STOP_AT${NC} (of $TOTAL_STEPS)"
if [ -n "$EPIC_NUM" ]; then
    echo -e "  Mode: ${CYAN}EPIC $EPIC_NUM${NC} — running all ready-for-dev stories sequentially"
fi
if [ "$VERBOSE" = true ]; then
    echo -e "  ${CYAN}VERBOSE MODE — streaming tool activity${NC}"
fi
if [ "$QUIET" = true ]; then
    echo -e "  ${DIM}QUIET MODE — progress only, LLM output suppressed${NC}"
fi
if [ "$DRY_RUN" = true ]; then
    echo -e "  ${YELLOW}DRY RUN MODE — no commands will execute${NC}"
fi

# --- Run pipeline for a single story ---
# This function runs steps 1-7 for the current STORY_FILE / STORY_CONTEXT.
# It is called once in single-story mode, or once per story in epic mode.
run_story_pipeline() {
    # Prompt for story file if not provided and needed for step 1
    if [ -z "$STORY_FILE" ] && [ "$START_AT" -le 1 ]; then
        echo ""
        echo -e "${YELLOW}No --story file specified. The dev-story workflow will auto-discover it.${NC}"
    fi

    STORY_CONTEXT=""
    if [ -n "$STORY_FILE" ]; then
        STORY_CONTEXT=" for the story at $STORY_FILE"
    fi

    # Account for skipped steps in progress tracking
    COMPLETED_STEPS=$(( START_AT - 1 ))

    # Step 1: Implement the story
    if [ "$START_AT" -le 1 ] && [ "$STOP_AT" -ge 1 ]; then
        step_header 1 "$MODEL_DEV" "Implement Story"
        # Touch sentinel now so we can detect which story file was created/modified
        touch "$TMPDIR_PIPELINE/story-detection-sentinel"
        run_claude 1 "$MODEL_DEV" \
            "Run the BMAD $WORKFLOW_DEV${STORY_CONTEXT}. Implement all tasks and subtasks, write tests, and update the story file per acceptance criteria."
        # If no story was specified upfront, detect which story step 1 worked on
        if [ -z "$STORY_FILE" ] && [ "$DRY_RUN" != true ]; then
            detected_story=$(find "$PROJECT_ROOT/$STORIES_DIR" -maxdepth 1 -name "*.md" \
                -newer "$TMPDIR_PIPELINE/story-detection-sentinel" \
                -exec ls -t {} + 2>/dev/null | head -1)
            if [ -n "$detected_story" ]; then
                STORY_FILE="${detected_story#"$PROJECT_ROOT/"}"
                STORY_CONTEXT=" for the story at $STORY_FILE"
                echo -e "  ${GREEN}Auto-detected story: ${CYAN}$STORY_FILE${NC}"
            else
                echo -e "${RED}  Could not auto-detect which story step 1 worked on.${NC}"
                echo -e "${RED}  Aborting — re-run with --story <id> to continue from step 2.${NC}"
                exit 1
            fi
        fi
        step_done 1 "Implement Story"
    fi

    # Step 2: Code review
    if [ "$START_AT" -le 2 ] && [ "$STOP_AT" -ge 2 ]; then
        step_header 2 "$MODEL_REVIEW" "Code Review"
        run_claude 2 "$MODEL_REVIEW" \
            "Run the BMAD $WORKFLOW_CODE_REVIEW${STORY_CONTEXT}. Perform a thorough adversarial code review. Save the review findings to a markdown file in $CODE_REVIEW_DIR/."
        step_done 2 "Code Review"
    fi

    # Step 3: Address code review findings
    if [ "$START_AT" -le 3 ] && [ "$STOP_AT" -ge 3 ]; then
        step_header 3 "$MODEL_FIX" "Address Code Review Findings"
        run_claude 3 "$MODEL_FIX" \
            "Look at the most recent code review file in $CODE_REVIEW_DIR/ (the one ending in code-review.md). Address ALL findings: critical, high, medium, and low severity items. Implement any recommended enhancements. After making fixes, update the review doc to mark items as resolved."
        step_done 3 "Address Code Review Findings"
    fi

    # Step 4: Test review
    if [ "$START_AT" -le 4 ] && [ "$STOP_AT" -ge 4 ]; then
        step_header 4 "$MODEL_REVIEW" "Test Review"
        run_claude 4 "$MODEL_REVIEW" \
            "Run the BMAD $WORKFLOW_TEST_REVIEW${STORY_CONTEXT}. Perform a thorough test quality review. The review output goes to $TEST_REVIEW_FILE."
        step_done 4 "Test Review"
    fi

    # Step 5: Address test review findings
    if [ "$START_AT" -le 5 ] && [ "$STOP_AT" -ge 5 ]; then
        step_header 5 "$MODEL_FIX" "Address Test Review Findings"
        run_claude 5 "$MODEL_FIX" \
            "Read the test review at $TEST_REVIEW_FILE. Address ALL findings: critical, high, medium, and low severity items. Implement any recommended enhancements. Fix any test quality issues identified."
        step_done 5 "Address Test Review Findings"
    fi

    # Step 6: Mark story as done in sprint status
    if [ "$START_AT" -le 6 ] && [ "$STOP_AT" -ge 6 ]; then
        step_header 6 "$MODEL_SPRINT" "Mark Story Done"
        run_claude 6 "$MODEL_SPRINT" \
            "Mark the current story as done in $SPRINT_STATUS_FILE. Find the story that was just implemented${STORY_CONTEXT} and update its status to 'done'. If there is a completed date field, set it to today's date."
        step_done 6 "Mark Story Done"
    fi

    # Step 7: Lint + pre-release checks (skipped if neither LINT_CMD nor PRERELEASE_CMD is set)
    if [ "$START_AT" -le 7 ] && [ "$STOP_AT" -ge 7 ] && { [ -n "$LINT_CMD" ] || [ -n "$PRERELEASE_CMD" ]; }; then
        step_header 7 "$MODEL_FIX" "Lint & Pre-Release Checks"
        STEP7_PROMPT="Perform final quality checks:"
        _step_num=1
        if [ -n "$LINT_CMD" ]; then
            STEP7_PROMPT+="
$_step_num. Run the lint command: $LINT_CMD. Fix any issues reported."
            _step_num=$(( _step_num + 1 ))
        fi
        if [ -n "$PRERELEASE_CMD" ]; then
            STEP7_PROMPT+="
$_step_num. Run: $PRERELEASE_CMD. Fix any warnings, errors, or test failures. Keep iterating until all checks pass."
        fi
        run_claude 7 "$MODEL_FIX" "$STEP7_PROMPT"
        step_done 7 "Lint & Pre-Release Checks"
    fi
}

# --- Execute: single story or epic loop ---

if [ -n "$EPIC_NUM" ]; then
    # Epic mode: loop through all ready-for-dev stories in the epic
    EPIC_STORIES_COMPLETED=0

    while true; do
        next_story_key=$(find_next_story_in_epic "$EPIC_NUM")

        if [ -z "$next_story_key" ]; then
            if [ "$EPIC_STORIES_COMPLETED" -eq 0 ]; then
                echo -e "${YELLOW}No ready-for-dev stories found in epic $EPIC_NUM.${NC}"
                exit 0
            else
                echo -e "${GREEN}All stories in epic $EPIC_NUM are complete.${NC}"
                break
            fi
        fi

        ((EPIC_STORIES_COMPLETED++))
        echo ""
        echo -e "${BLUE}╔══════════════════════════════════════════════════════════╗${NC}"
        echo -e "${BLUE}║  Epic $EPIC_NUM — Story $EPIC_STORIES_COMPLETED: ${next_story_key}${NC}"
        echo -e "${BLUE}╚══════════════════════════════════════════════════════════╝${NC}"

        # Resolve the story key to a file path
        STORY_FILE=$(resolve_story "$next_story_key")
        echo -e "  Story file: ${CYAN}$STORY_FILE${NC}"

        run_story_pipeline

        # Reset for next iteration
        STORY_FILE=""
        echo ""
        echo -e "${GREEN}  Story $next_story_key complete ($EPIC_STORIES_COMPLETED done so far)${NC}"
    done
else
    # Single story mode (original behavior)
    run_story_pipeline
fi

# Done
local_elapsed=$(( SECONDS - PIPELINE_START ))
local_min=$(( local_elapsed / 60 ))
local_sec=$(( local_elapsed % 60 ))
echo ""
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"
if [ -n "$EPIC_NUM" ]; then
    echo -e "${GREEN}  Epic $EPIC_NUM: $EPIC_STORIES_COMPLETED stories completed${NC}"
fi
echo -e "${GREEN}  $(progress_bar $TOTAL_STEPS $TOTAL_STEPS) ${TOTAL_STEPS}/${TOTAL_STEPS} complete${NC}"
echo -e "${GREEN}  Pipeline finished in ${local_min}m ${local_sec}s${NC}"
echo -e "${GREEN}  Logs: $LOG_DIR${NC}"
echo -e "${GREEN}══════════════════════════════════════════════════════════${NC}"

# Notify — terminal bell + macOS notification
printf '\a'
if command -v osascript &>/dev/null; then
    local_msg="Finished in ${local_min}m ${local_sec}s"
    if [ -n "$EPIC_NUM" ]; then
        local_msg="Epic $EPIC_NUM: $EPIC_STORIES_COMPLETED stories in ${local_min}m ${local_sec}s"
    fi
    osascript -e "display notification \"$local_msg\" with title \"Dev Story Pipeline\"" 2>/dev/null || true
fi
