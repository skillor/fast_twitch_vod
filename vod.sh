#!/usr/bin/env bash
set -u
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"

# --- Sensible Defaults ---
URL=""
PREFIX=""
REMOTE_DIR="nextcloud:Videos"
WORK_DIR="$HOME/vod_work"
TEMP_DIR="/dev/shm/td_temp"
CUSTOM_TEMP=0           # Tracks whether user explicitly passed -T
CHUNK_MINS=60           # 1 hour per part (~3-3.5 GB at 1080p60)
QUALITY=""              # Empty = best available; e.g. "1080p60" or "720p60"
THREADS=16              # Concurrent download threads for TwitchDownloaderCLI
MAX_QUEUED=3            # Max finished parts queued on disk for upload
OAUTH_TOKEN=""          # Optional Twitch OAuth token (for sub-only VODs)
START_INPUT=""          # Optional start time (HH:MM:SS, MM:SS, or seconds)
END_INPUT=""            # Optional end time (HH:MM:SS, MM:SS, or seconds)
AUTO_YES=0              # Set to 1 with -y to skip interactive space prompts
LIVE_FOLLOW=0           # Set to 1 with -W to download completed chunks live as stream grows
POLL_INTERVAL=60        # Seconds between checks when -W is active

usage() {
  cat << USAGE
Usage: $0 -u <VOD_URL_OR_ID> [options]

Options:
  -u <url|id>    Twitch VOD URL or numeric VOD ID (required)
  -n <name>      Output filename prefix (default: auto-generated)
  -d <remote>    rclone destination folder (default: $REMOTE_DIR)
  -w <dir>       Working directory for muxed queue (default: $WORK_DIR)
  -T <dir>       Temp directory for raw .ts segments (default: $TEMP_DIR)
  -c <minutes>   Segment length in minutes (default: $CHUNK_MINS)
  -s <time>      Start timestamp, e.g. 01:30:00 or 5400 (default: 00:00:00)
  -e <time>      End timestamp, e.g. 05:00:00 or 18000 (default: end of VOD)
  -q <quality>   Quality string e.g. 1080p60, 720p60 (default: best)
  -N <threads>   Concurrent download threads (default: $THREADS)
  -B <count>     Max parts queued on disk for upload (default: $MAX_QUEUED)
  -O <token>     Twitch OAuth token (optional, for sub-only VODs)
  -W             Live-follow mode: download full chunks as they become available,
                 then download the final partial chunk once VOD stops growing
  -i <seconds>   Poll interval in seconds when using -W (default: $POLL_INTERVAL)
  -y             Auto-confirm space warnings (recommended for nohup/cron)
  -h             Show this help message
USAGE
  exit 1
}

while getopts ":u:n:d:w:T:c:s:e:q:N:B:O:Wi:yh" opt; do
  case $opt in
    u) URL="$OPTARG" ;;
    n) PREFIX="$OPTARG" ;;
    d) REMOTE_DIR="$OPTARG" ;;
    w) WORK_DIR="$OPTARG" ;;
    T) TEMP_DIR="$OPTARG"; CUSTOM_TEMP=1 ;;
    c) CHUNK_MINS="$OPTARG" ;;
    s) START_INPUT="$OPTARG" ;;
    e) END_INPUT="$OPTARG" ;;
    q) QUALITY="$OPTARG" ;;
    N) THREADS="$OPTARG" ;;
    B) MAX_QUEUED="$OPTARG" ;;
    O) OAUTH_TOKEN="$OPTARG" ;;
    W) LIVE_FOLLOW=1 ;;
    i) POLL_INTERVAL="$OPTARG" ;;
    y) AUTO_YES=1 ;;
    h) usage ;;
    \?) echo "Unknown option: -$OPTARG" >&2; usage ;;
    :) echo "Option -$OPTARG requires an argument." >&2; usage ;;
  esac
done

if [[ -z "$URL" ]]; then
  echo "ERROR: -u <VOD_URL_OR_ID> is required." >&2
  usage
fi

for cmd in TwitchDownloaderCLI ffmpeg rclone; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[$(date)] ERROR: Required tool '$cmd' is missing." >&2
    exit 1
  fi
done

parse_time_to_sec() {
  local val="$1"
  if [[ "$val" =~ ^[0-9]+$ ]]; then
    echo "$val"
  elif [[ "$val" =~ ^([0-9]+):([0-9]{1,2}):([0-9]{1,2})$ ]]; then
    echo $(( 10#${BASH_REMATCH[1]} * 3600 + 10#${BASH_REMATCH[2]} * 60 + 10#${BASH_REMATCH[3]} ))
  elif [[ "$val" =~ ^([0-9]+):([0-9]{1,2})$ ]]; then
    echo $(( 10#${BASH_REMATCH[1]} * 60 + 10#${BASH_REMATCH[2]} ))
  else
    echo "-1"
  fi
}

format_sec() {
  local s="$1"
  printf "%02d:%02d:%02d" $((s/3600)) $(((s%3600)/60)) $((s%60))
}

confirm_or_abort() {
  local prompt_msg="$1"
  if [[ $AUTO_YES -eq 1 ]]; then
    echo "[$(date)] WARNING: $prompt_msg (auto-confirmed via -y)"
    return 0
  fi
  if [[ -t 0 ]]; then
    read -r -p "$prompt_msg [y/N]: " REPLY
    [[ "$REPLY" =~ ^[Yy]$ ]] && return 0
  else
    echo "[$(date)] ERROR: $prompt_msg (non-interactive shell; pass -y to override)" >&2
  fi
  exit 1
}

VOD_ID=$(echo "$URL" | grep -oE '[0-9]+' | tail -n 1)
if [[ -z "$VOD_ID" ]]; then
  echo "[$(date)] ERROR: Could not extract numeric VOD ID from '$URL'." >&2
  exit 1
fi

AUTH_ARGS=()
[[ -n "$OAUTH_TOKEN" ]] && AUTH_ARGS=(--oauth "$OAUTH_TOKEN")

QUALITY_ARGS=()
[[ -n "$QUALITY" ]] && QUALITY_ARGS=(-q "$QUALITY")

CHUNK_SEC=$(( CHUNK_MINS * 60 ))
mkdir -p "$WORK_DIR" "$TEMP_DIR"

# --- Storage & RAM Pre-flight Check ---
EST_PART_KB=$(( (CHUNK_MINS * 4718592 + 59) / 60 )) # ~4.5 GB per 60m
SAFETY_BUFFER_KB=5242880                            # 5 GB headroom

TEMP_AVAIL_KB=$(df -Pk "$TEMP_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
TEMP_REQ_KB=$(( EST_PART_KB + 1048576 ))            # 1 part + 1 GB buffer

if [[ -z "$TEMP_AVAIL_KB" || "$TEMP_AVAIL_KB" -lt "$TEMP_REQ_KB" ]]; then
  TEMP_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", ${TEMP_AVAIL_KB:-0}/1048576}")
  TEMP_REQ_GB=$(awk "BEGIN {printf \"%.1f\", $TEMP_REQ_KB/1048576}")
  if [[ $CUSTOM_TEMP -eq 0 ]]; then
    confirm_or_abort "$TEMP_DIR only has ${TEMP_AVAIL_GB} GB free (needs ~${TEMP_REQ_GB} GB for ${CHUNK_MINS}m temp segments). Fall back to $WORK_DIR/td_temp?"
    TEMP_DIR="$WORK_DIR/td_temp"
    mkdir -p "$TEMP_DIR"
  else
    confirm_or_abort "Custom temp dir $TEMP_DIR only has ${TEMP_AVAIL_GB} GB free (needs ~${TEMP_REQ_GB} GB). Continue anyway?"
  fi
fi

DISK_AVAIL_KB=$(df -Pk "$WORK_DIR" | awk 'NR==2 {print $4}')
SAME_FS=0
[[ "$(df -Pk "$TEMP_DIR" | awk 'NR==2 {print $1}')" == "$(df -Pk "$WORK_DIR" | awk 'NR==2 {print $1}')" ]] && SAME_FS=1

DISK_MULTIPLIER=$(( MAX_QUEUED + 1 ))
[[ $SAME_FS -eq 1 ]] && DISK_MULTIPLIER=$(( DISK_MULTIPLIER + 1 ))
DISK_REQ_KB=$(( EST_PART_KB * DISK_MULTIPLIER + SAFETY_BUFFER_KB ))

if [[ "$DISK_AVAIL_KB" -lt "$DISK_REQ_KB" ]]; then
  DISK_AVAIL_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_AVAIL_KB/1048576}")
  DISK_REQ_GB=$(awk "BEGIN {printf \"%.1f\", $DISK_REQ_KB/1048576}")
  confirm_or_abort "Low disk space on $WORK_DIR: ${DISK_AVAIL_GB} GB free, recommended ${DISK_REQ_GB} GB for ${CHUNK_MINS}m chunks (MAX_QUEUED=$MAX_QUEUED). Continue anyway?"
fi

DL_DIR="$WORK_DIR/downloading"
QUEUE_DIR="$WORK_DIR/upload_queue"
mkdir -p "$DL_DIR" "$QUEUE_DIR"
cd "$WORK_DIR" || exit 1

DONE_FLAG="$WORK_DIR/.download_finished"
FAIL_FLAG="$WORK_DIR/.upload_failed"
rm -f "$DONE_FLAG" "$FAIL_FLAG"

# --- Helper: Query VOD metadata ---
fetch_vod_info() {
  INFO_OUT=$(TwitchDownloaderCLI info --id "$VOD_ID" "${AUTH_ARGS[@]}" 2>&1 || true)
  STREAMER=$(echo "$INFO_OUT" | grep -iE 'Streamer|Channel' | head -n 1 | awk -F': ' '{print $2}' | tr -cd '[:alnum:]_-')
  LEN_STR=$(echo "$INFO_OUT" | grep -iE 'Length|Duration' | head -n 1 | grep -oE '[0-9]+(:[0-9]{2}){2,3}' | head -n 1)
  VOD_DURATION=0
  if [[ -n "$LEN_STR" ]]; then
    VOD_DURATION=$(awk -F: '{
      if (NF==4) print ($1*86400)+($2*3600)+($3*60)+$4;
      else if (NF==3) print ($1*3600)+($2*60)+$3;
      else print 0
    }' <<< "$LEN_STR")
  fi
}

# --- Initial Metadata Fetch ---
echo "[$(date)] Temp segments: $TEMP_DIR | Output queue: $WORK_DIR"
echo "[$(date)] Fetching VOD info for ID $VOD_ID..."
fetch_vod_info

# If -W is set and VOD hasn't appeared yet, wait for first segments to register
if [[ $LIVE_FOLLOW -eq 1 ]]; then
  while [[ "$VOD_DURATION" -le 0 ]]; do
    echo "[$(date)] [LIVE] VOD $VOD_ID not available yet. Retrying in ${POLL_INTERVAL}s..."
    sleep "$POLL_INTERVAL"
    fetch_vod_info
  done
fi

if [[ -z "$LEN_STR" || "$VOD_DURATION" -le 0 ]]; then
  echo "[$(date)] ERROR: Could not parse valid VOD duration from TwitchDownloaderCLI info." >&2
  echo "$INFO_OUT" >&2
  exit 1
fi

# --- Resolve Start & Optional Hard End Boundaries ---
RANGE_START=0
if [[ -n "$START_INPUT" ]]; then
  RANGE_START=$(parse_time_to_sec "$START_INPUT")
  if [[ "$RANGE_START" -lt 0 ]]; then
    echo "[$(date)] ERROR: Invalid start time format '$START_INPUT' (use HH:MM:SS, MM:SS, or seconds)." >&2
    exit 1
  fi
fi

USER_MAX_END=-1
if [[ -n "$END_INPUT" ]]; then
  USER_MAX_END=$(parse_time_to_sec "$END_INPUT")
  if [[ "$USER_MAX_END" -lt 0 ]]; then
    echo "[$(date)] ERROR: Invalid end time format '$END_INPUT' (use HH:MM:SS, MM:SS, or seconds)." >&2
    exit 1
  fi
  if (( RANGE_START >= USER_MAX_END )); then
    echo "[$(date)] ERROR: Start time (${RANGE_START}s) must be less than end time (${USER_MAX_END}s)." >&2
    exit 1
  fi
fi

[[ -z "$PREFIX" ]] && PREFIX="${STREAMER:-twitch}_${VOD_ID}"

# --- Background Upload Worker ---
upload_worker() {
  echo "[$(date)] [UPLOADER] Background upload worker started -> $REMOTE_DIR"
  while true; do
    [[ -f "$FAIL_FLAG" ]] && exit 1

    NEXT_FILE=$(find "$QUEUE_DIR" -maxdepth 1 -name "*.mp4" -type f | sort | head -n 1)
    if [[ -n "$NEXT_FILE" ]]; then
      BASENAME=$(basename "$NEXT_FILE")
      SIZE=$(du -h "$NEXT_FILE" | cut -f1)
      echo "[$(date)] [UPLOADER] Starting upload: $BASENAME ($SIZE)..."

      if rclone move "$NEXT_FILE" "$REMOTE_DIR/" --retries 5 --low-level-retries 10 --stats 30s -v; then
        echo "[$(date)] [UPLOADER] SUCCESS: $BASENAME uploaded and removed from $WORK_DIR."
      else
        echo "[$(date)] [UPLOADER] ERROR: Failed to upload $BASENAME!" >&2
        touch "$FAIL_FLAG"
        exit 1
      fi
    else
      if [[ -f "$DONE_FLAG" ]]; then
        echo "[$(date)] [UPLOADER] Queue empty and downloads finished. Uploader exiting."
        exit 0
      fi
      sleep 3
    fi
  done
}

UPLOADER_PID=""
cleanup() {
  if [[ -n "$UPLOADER_PID" ]] && kill -0 "$UPLOADER_PID" 2>/dev/null; then
    kill "$UPLOADER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEMP_DIR"/* "$DL_DIR"/*
}
trap cleanup INT TERM EXIT

echo "[$(date)] VOD: $PREFIX | Current Length: $LEN_STR | Live-Follow: $LIVE_FOLLOW | Chunk: ${CHUNK_MINS}m | Threads: $THREADS"

EXISTING_FILES=$(rclone lsf "$REMOTE_DIR" 2>/dev/null || true)

upload_worker &
UPLOADER_PID=$!

# --- Rolling Chunk Download Loop ---
PART_IDX=1
CUR_START=$RANGE_START
VOD_FINISHED=0
[[ $LIVE_FOLLOW -eq 0 ]] && VOD_FINISHED=1

while true; do
  TARGET_END=$(( CUR_START + CHUNK_SEC ))
  if [[ $USER_MAX_END -ge 0 && $TARGET_END -gt $USER_MAX_END ]]; then
    TARGET_END=$USER_MAX_END
  fi

  # If in live-follow mode and VOD hasn't reached TARGET_END yet, wait until either:
  #   1) VOD grows past TARGET_END (full chunk ready -> download immediately), OR
  #   2) VOD stops growing for 2 consecutive checks (stream ended/reconnected -> download final partial chunk)
  if [[ $VOD_FINISHED -eq 0 && $VOD_DURATION -lt $TARGET_END ]]; then
    PREV_DUR=$VOD_DURATION
    STABLE_CHECKS=0
    echo "[$(date)] [LIVE] Part $(printf "%02d" "$PART_IDX") needs $(format_sec "$TARGET_END"), VOD currently at $(format_sec "$VOD_DURATION"). Waiting for chunk to fill..."

    while true; do
      if [[ -f "$FAIL_FLAG" ]]; then
        echo "[$(date)] [DOWNLOADER] Aborting because background uploader failed." >&2
        exit 1
      fi

      sleep "$POLL_INTERVAL"
      fetch_vod_info

      if [[ "$VOD_DURATION" -ge "$TARGET_END" ]]; then
        echo "[$(date)] [LIVE] VOD reached $(format_sec "$VOD_DURATION") — full chunk ready!"
        break
      fi

      if [[ "$VOD_DURATION" -gt "$PREV_DUR" ]]; then
        echo "[$(date)] [LIVE] Stream still growing: $(format_sec "$PREV_DUR") -> $(format_sec "$VOD_DURATION") (waiting for $(format_sec "$TARGET_END"))..."
        PREV_DUR=$VOD_DURATION
        STABLE_CHECKS=0
      else
        STABLE_CHECKS=$(( STABLE_CHECKS + 1 ))
        if [[ $STABLE_CHECKS -ge 2 ]]; then
          echo "[$(date)] [LIVE] VOD stopped growing at $(format_sec "$VOD_DURATION") (2/2 checks). Downloading final partial chunk!"
          VOD_FINISHED=1
          break
        fi
        echo "[$(date)] [LIVE] VOD length unchanged at $(format_sec "$VOD_DURATION") ($STABLE_CHECKS/2 confirmation checks)..."
      fi
    done
  fi

  # Determine actual end timestamp for this chunk
  ACTUAL_END=$TARGET_END
  if [[ $ACTUAL_END -gt $VOD_DURATION ]]; then
    ACTUAL_END=$VOD_DURATION
  fi

  # If nothing left to download, exit loop cleanly
  if [[ $CUR_START -ge $ACTUAL_END ]]; then
    echo "[$(date)] [DOWNLOADER] Reached end of VOD at $(format_sec "$CUR_START")."
    break
  fi

  PART_NUM=$(printf "%02d" "$PART_IDX")
  START_COLON=$(format_sec "$CUR_START")
  END_COLON=$(format_sec "$ACTUAL_END")

  START_DASH=$(echo "$START_COLON" | tr ':' '-')
  END_DASH=$(echo "$END_COLON" | tr ':' '-')
  FILENAME="${PREFIX}_part${PART_NUM}_${START_DASH}_to_${END_DASH}.mp4"

  if echo "$EXISTING_FILES" | grep -Fxq "$FILENAME" || [[ -f "$QUEUE_DIR/$FILENAME" ]]; then
    echo "[$(date)] [DOWNLOADER] Skipping $FILENAME (already uploaded or queued)."
  else
    # Backpressure: wait if upload queue is full or disk free space drops below 1 part + 3 GB buffer
    MIN_RUNTIME_DISK_KB=$(( EST_PART_KB + 3145728 ))
    while true; do
      if [[ -f "$FAIL_FLAG" ]]; then
        echo "[$(date)] [DOWNLOADER] Aborting because background uploader failed." >&2
        exit 1
      fi
      QUEUED_COUNT=$(find "$QUEUE_DIR" -maxdepth 1 -name "*.mp4" -type f | wc -l | tr -d ' ')
      CUR_DISK_KB=$(df -Pk "$WORK_DIR" | awk 'NR==2 {print $4}')
      if (( QUEUED_COUNT < MAX_QUEUED && CUR_DISK_KB >= MIN_RUNTIME_DISK_KB )); then
        break
      fi
      sleep 5
    done

    echo "[$(date)] [DOWNLOADER] === Part $PART_NUM: Downloading $START_COLON -> $END_COLON ==="
    rm -f "$DL_DIR/$FILENAME"
    rm -rf "$TEMP_DIR"/*

    DOWNLOAD_OK=0
    for attempt in 1 2 3; do
      if TwitchDownloaderCLI videodownload \
        --id "$VOD_ID" \
        "${AUTH_ARGS[@]}" \
        "${QUALITY_ARGS[@]}" \
        -b "$START_COLON" \
        -e "$END_COLON" \
        -t "$THREADS" \
        --temp-path "$TEMP_DIR" \
        --banner false \
        -o "$DL_DIR/$FILENAME"; then
        DOWNLOAD_OK=1
        break
      fi
      echo "[$(date)] [DOWNLOADER] Attempt $attempt/3 failed for $FILENAME, retrying in 10s..."
      rm -rf "$TEMP_DIR"/*
      sleep 10
    done

    rm -rf "$TEMP_DIR"/*

    if [[ $DOWNLOAD_OK -ne 1 || ! -s "$DL_DIR/$FILENAME" ]]; then
      echo "[$(date)] [DOWNLOADER] ERROR: Failed to download $FILENAME after 3 attempts. Stopping." >&2
      touch "$FAIL_FLAG"
      wait "$UPLOADER_PID" 2>/dev/null || true
      exit 1
    fi

    mv "$DL_DIR/$FILENAME" "$QUEUE_DIR/$FILENAME"
    echo "[$(date)] [DOWNLOADER] Queued $FILENAME for upload!"
  fi

  CUR_START=$ACTUAL_END
  PART_IDX=$(( PART_IDX + 1 ))

  # Stop if we hit user's -e cap, or if VOD finished and we just downloaded up to VOD_DURATION
  if [[ $USER_MAX_END -ge 0 && $CUR_START -ge $USER_MAX_END ]]; then
    break
  fi
  if [[ $VOD_FINISHED -eq 1 && $CUR_START -ge $VOD_DURATION ]]; then
    break
  fi

  # Refresh VOD duration in static mode just in case, or keep current in live mode
  [[ $LIVE_FOLLOW -eq 0 ]] && fetch_vod_info
done

touch "$DONE_FLAG"
echo "[$(date)] [DOWNLOADER] All parts downloaded! Waiting for final upload(s) to finish..."

if wait "$UPLOADER_PID"; then
  rm -rf "$WORK_DIR" "$TEMP_DIR"
  echo "[$(date)] ALL PARTS DOWNLOADED AND UPLOADED!"
else
  echo "[$(date)] ERROR: Final upload failed." >&2
  exit 1
fi
