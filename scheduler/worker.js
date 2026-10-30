// simparty-monitor 예약 실행기 (Cloudflare Workers Cron Triggers) — 진입 모듈.
//
// 이 파일은 default export(scheduled 핸들러) 하나만 내보낸다. workerd 는 진입 모듈의 named export 를 각각
// entrypoint·handler 로 해석하므로, 문자열·함수 같은 named export 가 있으면 기동이 막힐 수 있다.
// 그래서 로직·상수는 lib.js 에 두고(테스트도 lib.js 를 import) 여기서는 묶기만 한다. 테스트가 이 규칙을 강제한다.
// 설명·크론·env 는 lib.js 머리말, 운영 절차는 README.md.
import { planDispatches, dispatch } from "./lib.js";

export default {
  async scheduled(controller, env, ctx) {
    // 모르는 크론이면 planDispatches 가 throw → Cron Events(Past Events)에 실패로 남는다
    const plan = planDispatches(controller.cron, controller.scheduledTime);
    let failed = 0;
    for (const d of plan) {
      if (!(await dispatch(d, env))) failed++;
    }
    // 실패를 던져 Cron Events 에 실패로 남긴다. 그동안은 GitHub schedule 대비책이 대신 돈다.
    if (failed > 0) throw new Error(`dispatch ${failed}/${plan.length}건 실패 (cron='${controller.cron}')`);
  },
};
