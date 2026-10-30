# 고정 비교 기준(L4): Cloudflare 예약 실행기 도입 전 main(6591464) 의 neon-usage.yml 'uptime 감시 heartbeat 조회'(id: hb) 스텝 run 블록.
# tests/schedule-gate.test.sh 가 'SCHEDULER 없음 = 옛 스텝과 같은 출력' 을 이 파일과 비교한다 — 머지 뒤에도 비교가 유지되도록 git 이 아니라 파일로 고정. 수정 금지.
# 실패해도 브리프는 보낸다 — 값이 비면 브리프에 "확인 불가" 로 표시
# 정기(schedule) 실행만 센다 — 수동 test-alert 는 체크 없이 성공하므로 heartbeat 를 리셋해 멈춘 스케줄을 가린다(F4)
last="$(gh run list --workflow uptime.yml --status success --event schedule --limit 1 --json createdAt -q '.[0].createdAt // ""' 2>/dev/null || true)"
echo "uptime.yml 마지막 성공: ${last:-없음}"
echo "last=${last}" >> "$GITHUB_OUTPUT"
# 최근 실행 목록 1회 조회(300건 ≈ 설계상 2일치) — 24h 실행 수·full 후보를 여기서 같이 뽑는다
runs="$(gh run list --workflow uptime.yml --limit 300 --json databaseId,displayTitle,createdAt,event 2>/dev/null || true)"
since="$(date -u -d '-24 hours' +%s)"
# 최근 24h 정기(schedule) 실행 수 · full 의도 수 — 설계 144·13 대비 GitHub cron 드롭 정도(경보 아님, 표시용)
runs24="$(jq -r --argjson s "$since" '[.[] | select(.event == "schedule" and (.createdAt | fromdateiso8601) >= $s)] | length' <<< "$runs" 2>/dev/null || true)"
full24="$(jq -r --argjson s "$since" '[.[] | select(.event == "schedule" and (.createdAt | fromdateiso8601) >= $s and ((.displayTitle // "") | endswith("· full")))] | length' <<< "$runs" 2>/dev/null || true)"
# DB 경유(full) 체크 heartbeat: full '의도' run(displayTitle '· full' — 강등돼도 이 제목) 중 'DB 경유(full) 실행 표식'
# 스텝과 체크 스텝이 둘 다 success 인 run = 실제로 DB 체크를 한 run (스텝 이름은 uptime.yml 과 동기).
#   full    = 그런 run 중 가장 최근의 체크 완료 시각
#   fullx24 = 최근 24h 안의 그런 run 수 (설계 13)
# 최신순 최대 20건만 본다(run 1건 = API 1회). 24h 밖으로 나갔고 full 을 찾았으면 멈춤.
full=""; fullx24=0
while read -r id created; do
  [ -n "$id" ] || continue
  t="$(gh run view "$id" --json jobs -q '[.jobs[]?.steps[]?] as $s
        | if any($s[]; .name == "DB 경유(full) 실행 표식" and .conclusion == "success")
          then ([$s[] | select(.name == "업타임 체크 + 장애 이슈/텔레그램" and .conclusion == "success") | .completedAt] | .[0] // "")
          else "" end' 2>/dev/null < /dev/null || true)"
  in24=0
  if [ "$(date -u -d "$created" +%s 2>/dev/null || echo 0)" -ge "$since" ]; then in24=1; fi
  if [ -n "$t" ] && [ "$t" != "null" ]; then
    [ -n "$full" ] || full="$t"
    if [ "$in24" = "1" ]; then fullx24=$((fullx24 + 1)); fi
  fi
  if [ "$in24" = "0" ] && [ -n "$full" ]; then break; fi
done < <(jq -r '.[] | select((.displayTitle // "") | endswith("· full")) | "\(.databaseId) \(.createdAt)"' <<< "$runs" 2>/dev/null | head -n 20 || true)
[ -n "$runs" ] || fullx24=""
echo "uptime.yml DB체크(full) 마지막 성공: ${full:-없음} · 최근 24h 정기 ${runs24:-?}회 / full 의도 ${full24:-?}회 / DB체크 실제 ${fullx24:-?}회"
{ echo "full=${full}"; echo "runs24=${runs24}"; echo "full24=${full24}"; echo "fullx24=${fullx24}"; } >> "$GITHUB_OUTPUT"
# 열린 업타임 장애 이슈 (uptime.sh 와 같은 판별: 봇 작성자 AND 라벨 AND 제목 키 AND PR 아님). 실패 = 빈 값 → "확인 불가"
inc="$(gh api "repos/${GH_REPO}/issues?state=open&labels=uptime-incident&per_page=100&sort=created&direction=asc" 2>/dev/null \
  | jq -c '[.[] | select((.pull_request == null)
        and ((.user.login // "") == "github-actions[bot]") and ((.user.type // "") == "Bot")
        and (((.labels // []) | map(.name? // .) | index("uptime-incident")) != null)
        and ((.title // "") | contains("[uptime] 장애 감지")))]
      | if length == 0 then {open: false}
        else .[0] | (.body // "") as $b | .created_at as $c
          | {open: true, number, url: .html_url,
             failed: ([$b | capture("<!-- failed: (?<v>[^ ]+) -->") | .v] | last // ""),
             since: ([$b | capture("<!-- down-since: (?<v>[^ ]+) -->") | .v] | last // $c)} end' 2>/dev/null || true)"
echo "열린 장애 이슈: ${inc:-확인 불가}"
echo "incident=${inc}" >> "$GITHUB_OUTPUT"
# 저장소 마지막 커밋 시각(epoch) — 공개 repo 60일 무활동 스케줄 자동 비활성 조기 경보용.
# checkout(fetch-depth 기본 1 = 얕은 체크아웃)도 HEAD 커밋 객체는 있으므로 git log -1 로 충분하다.
# 스케줄 run 의 HEAD = 기본 브랜치 최신 커밋. 실패하면 REST(커밋 목록 1건)로 대체, 둘 다 실패하면 빈 값 → 브리프 ⚠️
lc="$(git log -1 --format=%ct 2>/dev/null || true)"
if [ -z "$lc" ]; then
  iso="$(gh api "repos/${GH_REPO}/commits?per_page=1" --jq '.[0].commit.committer.date // ""' 2>/dev/null || true)"
  [ -z "$iso" ] || lc="$(date -u -d "$iso" +%s 2>/dev/null || true)"
fi
case "$lc" in ''|*[!0-9]*) lc="" ;; esac
echo "저장소 마지막 커밋(epoch): ${lc:-확인 불가}"
echo "last_commit=${lc}" >> "$GITHUB_OUTPUT"
