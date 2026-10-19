#!/usr/bin/env bash
# 서버 여러 대(systemd mafia-server@{포트}) 순차 재시작 배포. EC2에서 실행한다.
#
# 사용
#   ./deploy.sh <새 jar>     새 jar로 바꾸고 한 대씩 재시작 (기본 8080 → 8081)
#   ./deploy.sh --rollback   직전 jar(app.jar.prev)로 되돌리고 한 대씩 재시작
#   ./deploy.sh --restart    jar는 그대로, 한 대씩 재시작만 (.env를 바꿨을 때 등)
#
# 흐름
#  1) 지금 jar를 app.jar.prev로 보관하고, 새 jar를 app.jar.new로 복사한 뒤 mv로 바꾼다.
#     실행 중인 jar를 덮어쓰면 그 JVM이 죽을 수 있다. mv는 이름만 바꾸므로 돌고 있는 서버는 옛 파일을 계속 쓴다.
#  2) 서버를 한 대씩 재시작한다. 재시작 전에 "다른 서버가 요청을 받고 있는지" 확인한다. (없으면 다운타임이라 멈춘다)
#     정상 종료(server.shutdown=graceful)가 WebSocket을 1001로 닫으면 클라이언트가 다시 연결하고, nginx가 살아 있는 서버로 붙인다.
#  3) /actuator/health/readiness가 UP(DB·Redis 연결까지 확인)이 될 때까지 기다린 뒤 다음 서버로 넘어간다.
#     다음 서버 전에 SETTLE_SECONDS만큼 쉰다. nginx는 재시작 중 연결이 거부된 서버를 fail_timeout(10초) 동안 빼 두므로,
#     바로 다음 서버를 끄면 nginx가 보낼 곳이 없어 잠깐 502가 날 수 있다.
#  4) 한 대라도 준비되지 않으면 거기서 멈춘다. 나머지 서버는 건드리지 않으므로 서비스는 이어진다. --rollback으로 되돌린다.
#
# 바꿀 수 있는 값 (환경변수)
#   APP_DIR=/opt/mafia  PORTS="8080 8081"  READY_TIMEOUT_SECONDS=120  SETTLE_SECONDS=12
#   FORCE=1 : 다른 서버가 준비되지 않았어도 재시작한다 (서버 1대 운영 등, 다운타임 발생)
set -euo pipefail

APP_DIR=${APP_DIR:-/opt/mafia}
# shellcheck disable=SC2206  # 공백으로 나눠 배열로 만드는 것이 의도
PORTS=(${PORTS:-8080 8081})
READY_TIMEOUT_SECONDS=${READY_TIMEOUT_SECONDS:-120}
SETTLE_SECONDS=${SETTLE_SECONDS:-12}
FORCE=${FORCE:-0}

JAR="$APP_DIR/app.jar"
PREV="$APP_DIR/app.jar.prev"

log() { printf '[deploy %s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf '[deploy %s] 실패: %s\n' "$(date +%H:%M:%S)" "$*" >&2; exit 1; }

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

# 요청을 받아도 되는가 (DB·Redis까지 확인, 종료가 시작되면 바로 DOWN)
is_ready() {
  curl -sf -o /dev/null --max-time 3 "http://127.0.0.1:$1/actuator/health/readiness"
}

wait_ready() {
  local port=$1 deadline=$((SECONDS + READY_TIMEOUT_SECONDS))
  while (( SECONDS < deadline )); do
    is_ready "$port" && return 0
    sleep 2
  done
  return 1
}

# 응답 헤더 X-Server-Id (systemd 템플릿이 server-{포트}로 정한다)
server_id() {
  curl -s -o /dev/null -D - --max-time 3 "http://127.0.0.1:$1/actuator/health/readiness" \
    | tr -d '\r' | awk -F': ' 'tolower($1) == "x-server-id" { print $2 }'
}

# 이 포트 말고 요청을 받을 수 있는 서버가 하나라도 있는가
others_ready() {
  local p
  for p in "${PORTS[@]}"; do
    [[ $p == "$1" ]] && continue
    is_ready "$p" && return 0
  done
  return 1
}

check_jar() {
  [[ -f $1 ]] || die "파일이 없습니다: $1"
  [[ $(head -c 2 "$1") == "PK" ]] || die "jar(zip) 파일이 아닙니다: $1"
}

short_hash() { sha256sum "$1" | cut -c1-12; }

# 새 jar를 app.jar 자리에 넣는다. 같은 폴더에 복사한 뒤 mv (같은 파일 시스템이라 한 번에 바뀐다)
install_jar() {
  cp "$1" "$JAR.new"
  mv -f "$JAR.new" "$JAR"
}

rolling_restart() {
  # 지금 준비되지 않은 서버를 먼저 재시작한다. 이미 요청을 못 받는 서버라 다운타임이 늘지 않고,
  # 그래야 실패한 배포를 되돌릴 때(--rollback) 꺼져 있는 서버 때문에 멈추지 않는다.
  local order=() p i port
  for p in "${PORTS[@]}"; do is_ready "$p" || order+=("$p"); done
  for p in "${PORTS[@]}"; do is_ready "$p" && order+=("$p"); done

  for i in "${!order[@]}"; do
    port=${order[$i]}
    if is_ready "$port" && ! others_ready "$port"; then
      if [[ $FORCE == 1 ]]; then
        log "경고: [$port] 외에 요청을 받을 서버가 없습니다. FORCE=1이라 재시작합니다 (다운타임 발생)"
      else
        die "[$port] 외에 요청을 받을 서버가 없어 재시작하면 서비스가 끊깁니다. 다른 서버 상태를 확인하거나 FORCE=1로 실행하세요"
      fi
    fi

    log "[$port] 재시작 (WebSocket을 1001로 닫고 처리 중인 요청을 마친 뒤 꺼짐, 최대 약 20초)"
    sudo systemctl restart "mafia-server@$port"

    if ! wait_ready "$port"; then
      sudo journalctl -u "mafia-server@$port" -n 40 --no-pager >&2 || true
      die "[$port] ${READY_TIMEOUT_SECONDS}초 안에 준비되지 않았습니다. 다음 서버는 건드리지 않았습니다. 되돌리기: $0 --rollback"
    fi
    log "[$port] 준비됨 (X-Server-Id: $(server_id "$port"))"

    if (( i < ${#order[@]} - 1 )); then
      log "${SETTLE_SECONDS}초 대기 (nginx가 [$port]를 다시 받고, 클라이언트가 다시 연결할 시간)"
      sleep "$SETTLE_SECONDS"
    fi
  done
}

main() {
  [[ $# -eq 1 ]] || usage 1

  # 배포를 두 개 동시에 돌리지 않게 잠근다 (스크립트가 끝나면 자동으로 풀린다)
  exec 9>"$APP_DIR/.deploy.lock"
  flock -n 9 || die "다른 배포가 진행 중입니다 ($APP_DIR/.deploy.lock)"

  case $1 in
    -h|--help)
      usage 0
      ;;
    --restart)
      check_jar "$JAR"
      log "jar는 그대로 두고 재시작합니다 (app.jar $(short_hash "$JAR"))"
      ;;
    --rollback)
      check_jar "$PREV"
      log "되돌리기: app.jar $(short_hash "$JAR") → app.jar.prev $(short_hash "$PREV")"
      install_jar "$PREV"
      ;;
    -*)
      usage 1
      ;;
    *)
      check_jar "$1"
      if [[ -f $JAR ]] && cmp -s "$1" "$JAR"; then
        die "지금 쓰는 app.jar와 같은 파일입니다. 재시작만 하려면 $0 --restart"
      fi
      if [[ -f $JAR ]]; then
        cp "$JAR" "$PREV"
        log "이전 jar 보관: app.jar.prev ($(short_hash "$PREV"))"
      fi
      install_jar "$1"
      log "새 jar 설치: app.jar ($(short_hash "$JAR"))"
      ;;
  esac

  rolling_restart
  log "완료: ${PORTS[*]} 모두 준비됨"
}

main "$@"
