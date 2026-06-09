#!/bin/bash
# ============================================================
# 艾宾浩斯遗忘曲线复习提醒 - 命令行工具
# ============================================================
# 用法:
#   ebbinghaus.sh add "背诵内容" ["备注"]
#   ebbinghaus.sh list
#   ebbinghaus.sh today
#   ebbinghaus.sh review <id>
#   ebbinghaus.sh notify
#   ebbinghaus.sh cron-setup
#   ebbinghaus.sh stats
# ============================================================

set -euo pipefail

DATA_DIR="$HOME/.ebbinghaus"
DATA_FILE="$DATA_DIR/data.json"
SCRIPT_NAME="$(basename "$0")"

# 艾宾浩斯遗忘曲线复习间隔（毫秒）
# 轮次1: 1天, 轮次2: 2天, 轮次3: 4天, 轮次4: 7天, 轮次5: 15天, 轮次6: 1个月
INTERVALS_MS=(
  86400000         # 1 * 24 * 60 * 60 * 1000
  172800000        # 2 * 24 * 60 * 60 * 1000
  345600000        # 4 * 24 * 60 * 60 * 1000
  604800000        # 7 * 24 * 60 * 60 * 1000
  1296000000       # 15 * 24 * 60 * 60 * 1000
  2592000000       # 30 * 24 * 60 * 60 * 1000
)

INTERVAL_LABELS=(
  "1天后"
  "2天后"
  "4天后"
  "7天后"
  "15天后"
  "1个月后"
)

# 颜色
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# ============================================================
# 工具函数
# ============================================================

init_data() {
  if [ ! -d "$DATA_DIR" ]; then
    mkdir -p "$DATA_DIR"
  fi
  if [ ! -f "$DATA_FILE" ]; then
    echo '{"items":[]}' > "$DATA_FILE"
  fi
  # Validate JSON
  if ! jq empty "$DATA_FILE" 2>/dev/null; then
    echo -e "${RED}错误：数据文件损坏，已备份并重新初始化${NC}"
    cp "$DATA_FILE" "$DATA_FILE.bak.$(date +%s)"
    echo '{"items":[]}' > "$DATA_FILE"
  fi
}

generate_id() {
  local ts=$(date +%s)
  local rand=$(od -A n -t d -N 3 /dev/urandom 2>/dev/null | tr -d ' ' || echo $((RANDOM * RANDOM)))
  echo "$(printf '%x' $ts)$(printf '%x' $rand)"
}

timestamp_ms_to_iso() {
  # Convert Unix timestamp in milliseconds to ISO 8601
  local ms=$1
  local sec=$((ms / 1000))
  date -j -f '%s' "$sec" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "@$sec" '+%Y-%m-%dT%H:%M:%S'
}

iso_to_timestamp_ms() {
  # Convert ISO 8601 to Unix timestamp in milliseconds
  local iso=$1
  local sec=$(date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%.*}" '+%s' 2>/dev/null || date -d "$iso" '+%s')
  echo $((sec * 1000))
}

get_status() {
  local next_review=$1
  local now_ms=$(($(date +%s) * 1000))
  local review_ms=$(iso_to_timestamp_ms "$next_review" 2>/dev/null || echo 0)

  if [ "$review_ms" = "0" ]; then
    echo "unknown"
    return
  fi

  local today_start
  today_start=$(date -j -f '%s' "$(($(date +%s) / 86400 * 86400))" '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -d "today 00:00:00" '+%Y-%m-%dT%H:%M:%S')
  local today_start_ms=$(iso_to_timestamp_ms "$today_start")

  if [ "$review_ms" -le "$now_ms" ]; then
    if [ "$review_ms" -lt "$today_start_ms" ]; then
      echo "overdue"
    else
      echo "today"
    fi
  else
    echo "upcoming"
  fi
}

format_date() {
  local iso=$1
  if [ -z "$iso" ] || [ "$iso" = "null" ]; then
    echo "-"
    return
  fi
  # macOS date format
  date -j -f '%Y-%m-%dT%H:%M:%S' "${iso%.*}" '+%m/%d %H:%M' 2>/dev/null || date -d "$iso" '+%m/%d %H:%M'
}

# ============================================================
# 命令实现
# ============================================================

cmd_add() {
  local name="${1:-}"
  local desc="${2:-}"
  local date_input="${3:-}"

  if [ -z "$name" ]; then
    echo -e "${RED}用法: $SCRIPT_NAME add \"背诵内容\" [\"备注\"] [YYYY-MM-DD]${NC}"
    echo -e "  YYYY-MM-DD: 学习日期，默认为今天；可填入过去日期补录"
    exit 1
  fi

  init_data

  local id=$(generate_id)
  local created_at
  local created_at_ms

  if [ -n "$date_input" ] && date -j -f '%Y-%m-%d' "$date_input" '+%Y-%m-%d' &>/dev/null; then
    # Use specified date at noon
    created_at="${date_input}T12:00:00"
    created_at_ms=$(($(date -j -f '%Y-%m-%d %H:%M:%S' "${date_input} 12:00:00" '+%s') * 1000))
    echo -e "${CYAN}📅 使用指定日期：${date_input}${NC}"
  else
    if [ -n "$date_input" ]; then
      echo -e "${RED}日期格式无效，使用今天${NC}"
    fi
    created_at=$(date '+%Y-%m-%dT%H:%M:%S')
    created_at_ms=$(($(date +%s) * 1000))
  fi

  local first_review_ms=$((created_at_ms + INTERVALS_MS[0]))
  local first_review=$(timestamp_ms_to_iso $first_review_ms)

  # Escape special characters for jq
  local new_item=$(jq -n \
    --arg id "$id" \
    --arg name "$name" \
    --arg desc "$desc" \
    --arg createdAt "$created_at" \
    --arg nextReview "$first_review" \
    '{
      id: $id,
      name: $name,
      description: $desc,
      content: "",
      createdAt: $createdAt,
      currentRound: 1,
      nextReviewDate: $nextReview,
      reviewHistory: []
    }')

  jq ".items += [$new_item]" "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"

  echo -e "${GREEN}✓ 已添加背诵内容${NC}"
  echo -e "  ${BOLD}名称：${NC}$name"
  if [ -n "$desc" ]; then
    echo -e "  ${BOLD}备注：${NC}$desc"
  fi
  echo -e "  ${BOLD}ID：${NC}$id"
  echo -e "  ${BOLD}学习日期：${NC}$(echo "$created_at" | cut -dT -f1)"
  echo -e "  ${BOLD}首次复习：${NC}$(format_date "$first_review")（第1轮 · ${INTERVAL_LABELS[0]}）"

  # Check if past date means reviews are overdue
  local now_ms=$(($(date +%s) * 1000))
  if [ "$first_review_ms" -lt "$now_ms" ]; then
    echo -e "  ${RED}⚠️  首次复习已逾期，请尽快完成！${NC}"
  fi

  echo ""
  echo -e "${CYAN}💡 所有 6 轮复习时间：${NC}"
  for i in 0 1 2 3 4 5; do
    local review_ms=$((created_at_ms + INTERVALS_MS[$i]))
    local review_date=$(timestamp_ms_to_iso $review_ms)
    local status=""
    if [ "$review_ms" -lt "$now_ms" ]; then
      status=" ${RED}(已逾期)${NC}"
    fi
    echo -e "  第$((i+1))轮 · ${INTERVAL_LABELS[$i]}：$(format_date "$review_date")${status}"
  done
}

cmd_list() {
  init_data

  local count=$(jq '.items | length' "$DATA_FILE")
  if [ "$count" -eq 0 ]; then
    echo -e "${YELLOW}还没有任何背诵内容。使用 add 命令添加。${NC}"
    exit 0
  fi

  echo -e "${BOLD}📚 全部背诵内容（共 $count 条）${NC}\n"

  jq -r '.items[] |
    "\(.id)|\(.name)|\(.description // "")|\(.currentRound)|\(.nextReviewDate // "")|\(.createdAt)"' "$DATA_FILE" |
  while IFS='|' read -r id name desc round next_review created; do
    local status=$(get_status "$next_review")
    local round_label=""
    local status_icon=""
    local status_color=""

    if [ "$round" -gt 6 ]; then
      round_label="已完成"
      status_icon="✅"
      status_color="$GREEN"
    else
      round_label="第${round}轮 · ${INTERVAL_LABELS[$((round - 1))]}"
      case "$status" in
        overdue)
          status_icon="⚠️ "
          status_color="$RED"
          ;;
        today)
          status_icon="📋"
          status_color="$YELLOW"
          ;;
        upcoming)
          status_icon="📅"
          status_color="$BLUE"
          ;;
      esac
    fi

    echo -e "${status_color}${status_icon}${NC} ${BOLD}${name}${NC}"
    echo -e "  ID: ${id}  |  ${round_label}  |  下次复习: $(format_date "$next_review")"
    if [ -n "$desc" ]; then
      echo -e "  备注: ${desc}"
    fi
    echo ""
  done
}

cmd_today() {
  init_data

  echo -e "${BOLD}📋 今日待复习${NC}\n"

  local found=0
  jq -r '.items[] |
    "\(.id)|\(.name)|\(.description // "")|\(.currentRound)|\(.nextReviewDate // "")|\(.createdAt)"' "$DATA_FILE" |
  while IFS='|' read -r id name desc round next_review created; do
    local status=$(get_status "$next_review")
    if [ "$status" = "today" ] || [ "$status" = "overdue" ]; then
      found=1
      local status_label=""
      if [ "$status" = "overdue" ]; then
        status_label="${RED}⚠️  已逾期${NC}"
      else
        status_label="${YELLOW}📋 今天${NC}"
      fi

      local round_label=""
      if [ "$round" -gt 6 ]; then
        round_label="已完成"
      else
        round_label="第${round}轮 · ${INTERVAL_LABELS[$((round - 1))]}"
      fi

      echo -e "${status_label} ${BOLD}${name}${NC}"
      echo -e "  ID: ${id}  |  ${round_label}  |  计划时间: $(format_date "$next_review")"
      if [ -n "$desc" ]; then
        echo -e "  备注: ${desc}"
      fi
      echo ""
    fi
  done

  if [ "$found" -eq 0 ]; then
    echo -e "${GREEN}🎉 今天没有需要复习的内容！${NC}"
  fi
}

cmd_review() {
  local target_id="${1:-}"

  if [ -z "$target_id" ]; then
    echo -e "${RED}用法: $SCRIPT_NAME review <id>${NC}"
    echo -e "先用 list 命令查看各条目的 ID"
    exit 1
  fi

  init_data

  # Check if item exists
  local item=$(jq -r ".items[] | select(.id == \"$target_id\")" "$DATA_FILE")
  if [ -z "$item" ]; then
    echo -e "${RED}错误：找不到 ID 为 \"$target_id\" 的条目${NC}"
    exit 1
  fi

  local name=$(echo "$item" | jq -r '.name')
  local round=$(echo "$item" | jq -r '.currentRound')
  local created=$(echo "$item" | jq -r '.createdAt')
  local next_review=$(echo "$item" | jq -r '.nextReviewDate')
  local now=$(date '+%Y-%m-%dT%H:%M:%S')

  if [ "$round" -gt 6 ]; then
    echo -e "${YELLOW}「${name}」已经完成全部 6 轮复习${NC}"
    exit 0
  fi

  # Calculate next review date
  local created_ms=$(iso_to_timestamp_ms "$created")
  local next_review_ms
  if [ "$round" -lt 6 ]; then
    next_review_ms=$((created_ms + INTERVALS_MS[$round]))
  else
    next_review_ms=0
  fi
  local next_review_date="null"
  if [ "$next_review_ms" -gt 0 ]; then
    next_review_date=$(timestamp_ms_to_iso $next_review_ms)
  fi

  # Update item
  local completed_entry=$(jq -n \
    --arg scheduled "$next_review" \
    --arg completedAt "$now" \
    --argjson round "$round" \
    '{round: $round, scheduledDate: $scheduled, completedAt: $completedAt}')

  jq \
    --arg id "$target_id" \
    --argjson completedEntry "$completed_entry" \
    --arg nextReview "$next_review_date" \
    --argjson newRound $((round + 1)) \
    '(.items[] | select(.id == $id)) |= (.reviewHistory += [$completedEntry] | .currentRound = $newRound | .nextReviewDate = $nextReview)' \
    "$DATA_FILE" > "$DATA_FILE.tmp" && mv "$DATA_FILE.tmp" "$DATA_FILE"

  echo -e "${GREEN}✅ 已完成「${name}」第 ${round} 轮复习！${NC}"

  if [ "$round" -lt 6 ]; then
    local next_label="${INTERVAL_LABELS[$round]}"
    echo -e "  ${BOLD}下一轮（第$((round + 1))轮 · ${next_label}）：${NC}$(format_date "$next_review_date")"
  else
    echo -e "  ${GREEN}🎉 恭喜！全部 6 轮复习已完成！${NC}"
  fi
}

cmd_notify() {
  init_data

  local found=0
  local message=""

  while IFS='|' read -r name round next_review; do
    local status=$(get_status "$next_review")
    if [ "$status" = "today" ] || [ "$status" = "overdue" ]; then
      found=$((found + 1))
      local round_label=""
      if [ "$round" -le 6 ]; then
        round_label="第${round}轮"
      else
        round_label="已完成"
      fi
      message="${message}${name}（${round_label}）\n"
    fi
  done < <(jq -r '.items[] | "\(.name)|\(.currentRound)|\(.nextReviewDate // "")"' "$DATA_FILE")

  if [ "$found" -eq 0 ]; then
    echo -e "${GREEN}没有需要复习的内容${NC}"
    return
  fi

  echo -e "${YELLOW}📋 今日有 ${found} 项需要复习：${NC}"
  echo -e "$message"

  # Send macOS notification using osascript
  if command -v osascript &>/dev/null; then
    local title="🧠 艾宾浩斯复习提醒"
    local subtitle="今天有 ${found} 项内容需要复习"
    local body=$(echo -e "$message" | head -5 | tr '\n' ' ')

    osascript -e "display notification \"$body\" with title \"$title\" subtitle \"$subtitle\" sound name \"Glass\""
    echo -e "${GREEN}✓ 已发送系统通知${NC}"
  else
    echo -e "${YELLOW}⚠️  当前系统不支持 osascript（非 macOS）${NC}"
  fi
}

cmd_stats() {
  init_data

  local total=$(jq '.items | length' "$DATA_FILE")
  if [ "$total" -eq 0 ]; then
    echo -e "${YELLOW}还没有任何背诵内容${NC}"
    exit 0
  fi

  local overdue=0 today=0 upcoming=0 completed=0

  while IFS='|' read -r round next_review; do
    if [ "$round" -gt 6 ]; then
      completed=$((completed + 1))
      continue
    fi
    local status=$(get_status "$next_review")
    case "$status" in
      overdue) overdue=$((overdue + 1)) ;;
      today) today=$((today + 1)) ;;
      upcoming) upcoming=$((upcoming + 1)) ;;
    esac
  done < <(jq -r '.items[] | "\(.currentRound)|\(.nextReviewDate // "")"' "$DATA_FILE")

  local total_reviews=$(jq '[.items[].reviewHistory | length] | add // 0' "$DATA_FILE")

  echo -e "${BOLD}📊 统计信息${NC}\n"
  echo -e "  总条目数：    ${BOLD}${total}${NC}"
  echo -e "  累计复习次数：${BOLD}${total_reviews}${NC}"
  echo -e "  已完成：      ${GREEN}${completed}${NC} 条"
  echo -e "  今日待复习：  ${YELLOW}${today}${NC} 条"
  echo -e "  已逾期：      ${RED}${overdue}${NC} 条"
  echo -e "  即将到来：    ${BLUE}${upcoming}${NC} 条"
}

cmd_cron_setup() {
  local script_path
  if command -v "$SCRIPT_NAME" &>/dev/null; then
    script_path=$(command -v "$SCRIPT_NAME")
  else
    script_path="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
  fi

  echo -e "${BOLD}🔧 crontab 配置建议${NC}\n"
  echo -e "将以下行添加到 crontab 即可自动提醒：\n"
  echo -e "${CYAN}# 每天早上 9:07 发送复习提醒${NC}"
  echo -e "${BOLD}7 9 * * * ${script_path} notify${NC}"
  echo ""
  echo -e "${CYAN}# 每天下午 2:07 发送复习提醒${NC}"
  echo -e "${BOLD}7 14 * * * ${script_path} notify${NC}"
  echo ""
  echo -e "${CYAN}# 每天晚上 8:07 发送复习提醒${NC}"
  echo -e "${BOLD}7 20 * * * ${script_path} notify${NC}"
  echo ""
  echo -e "${YELLOW}操作步骤：${NC}"
  echo -e "  1. 运行 ${BOLD}crontab -e${NC} 打开编辑器"
  echo -e "  2. 粘贴上面需要的行"
  echo -e "  3. 保存退出即可"
  echo ""
  echo -e "${YELLOW}⚠️  确保脚本有可执行权限：${NC}"
  echo -e "  ${BOLD}chmod +x ${script_path}${NC}"
}

cmd_help() {
  echo -e "${BOLD}🧠 艾宾浩斯遗忘曲线复习提醒工具${NC}\n"
  echo -e "用法: ${BOLD}$SCRIPT_NAME <命令> [参数]${NC}\n"
  echo -e "${BOLD}命令：${NC}"
  echo -e "  ${GREEN}add${NC} \"名称\" [\"备注\"] [日期]  添加背诵内容，日期格式 YYYY-MM-DD（默认今天）"
  echo -e "  ${GREEN}list${NC}                   列出所有条目"
  echo -e "  ${GREEN}today${NC}                  查看今日待复习内容"
  echo -e "  ${GREEN}review${NC} <id>            标记某条目完成当前轮次复习"
  echo -e "  ${GREEN}notify${NC}                 发送系统通知（今日待复习）"
  echo -e "  ${GREEN}stats${NC}                  显示统计信息"
  echo -e "  ${GREEN}cron-setup${NC}             显示 crontab 自动提醒配置"
  echo -e "  ${GREEN}help${NC}                   显示此帮助信息\n"
  echo -e "${BOLD}艾宾浩斯复习节点：${NC}"
  for i in 0 1 2 3 4 5; do
    echo -e "  第$((i+1))轮：${INTERVAL_LABELS[$i]}"
  done
  echo ""
  echo -e "数据文件：${CYAN}${DATA_FILE}${NC}"
  echo -e "网页版：${CYAN}打开 index.html 即可使用${NC}"
}

# ============================================================
# 主入口
# ============================================================

main() {
  local cmd="${1:-help}"

  case "$cmd" in
    add)
      cmd_add "${2:-}" "${3:-}" "${4:-}"
      ;;
    list|ls)
      cmd_list
      ;;
    today|t)
      cmd_today
      ;;
    review|done|r)
      cmd_review "${2:-}"
      ;;
    notify|n)
      cmd_notify
      ;;
    stats|s)
      cmd_stats
      ;;
    cron-setup|cron)
      cmd_cron_setup
      ;;
    help|--help|-h)
      cmd_help
      ;;
    *)
      echo -e "${RED}未知命令: $cmd${NC}\n"
      cmd_help
      exit 1
      ;;
  esac
}

main "$@"
