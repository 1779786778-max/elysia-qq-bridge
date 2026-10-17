// 上线 / 下线播报（announce）：QQ 机器人上下线时，给白名单里的**私聊**用户各发一条通知。
//
// 行为（按用户要求）：
//   · 上线 → 给白名单用户发「已上线」
//   · 下机 → 给白名单用户发「已下线」
//   · **只走私聊**：群聊一条都不发（哪怕群在白名单里）
//
// 为什么单开一个模块而不是写进 bridge.js：
//   1) 「发给谁 / 失败怎么重试」这段规则可以脱离桥接单独验证（不碰 WebSocket，全依赖注入）；
//   2) 主收发链路上只留几行接线，出问题时一眼能看出是播报还是主链路；
//   3) 以后想改成「只通知主号」或加别的触发点，只动这一个文件。
//
// 配置（config.json 的 announce 段，整段缺省也能用，默认值见 ANNOUNCE_DEFAULTS）：
//   "announce": {
//     "enabled": true,      // false = 关掉播报
//     "online": "已上线",    // 上线文案
//     "offline": "已下线",   // 下线文案
//     "to": [],             // 留空 = 用 allow.private；填了就只发给这里列出的号
//     "attempts": 4,        // 最多尝试几次（每次给所有对象发一轮）
//     "gapMs": 6000         // 两次尝试之间的间隔
//   }

export const ANNOUNCE_DEFAULTS = {
  enabled: true,
  online: '已上线',
  offline: '已下线',
  attempts: 4,
  gapMs: 6000
};

/** 归一化播报配置：数值做范围钳制，文案取字符串，缺省用默认值。 */
export function announceSettings(cfg) {
  const raw = cfg?.announce ?? {};
  const attempts = Number(raw.attempts);
  const gapMs = Number(raw.gapMs);
  const text = (value, fallback) => {
    const s = String(value ?? '').trim();
    return s || fallback;
  };
  return {
    enabled: raw.enabled !== false,
    online: text(raw.online, ANNOUNCE_DEFAULTS.online),
    offline: text(raw.offline, ANNOUNCE_DEFAULTS.offline),
    attempts: Number.isFinite(attempts) ? Math.min(10, Math.max(1, Math.round(attempts))) : ANNOUNCE_DEFAULTS.attempts,
    gapMs: Number.isFinite(gapMs) ? Math.min(60000, Math.max(500, Math.round(gapMs))) : ANNOUNCE_DEFAULTS.gapMs
  };
}

/**
 * 播报对象 = 私聊白名单（announce.to 非空时以它为唯一来源），
 * 去重、只保留纯数字 QQ 号、并剔除 deny.private 里的号。
 *
 * 返回的永远是 `private:<QQ>` 形式的会话 key —— 群聊不可能出现在这里（这是刻意的）。
 */
export function announceTargets(cfg) {
  const configured = Array.isArray(cfg?.announce?.to) ? cfg.announce.to : [];
  const raw = configured.length ? configured : (cfg?.allow?.private ?? []);
  const deny = new Set((cfg?.deny?.private ?? []).map((v) => String(v)));
  const out = [];
  for (const value of raw) {
    const s = String(value ?? '').trim();
    if (!/^\d+$/.test(s)) continue;      // 非法/占位值直接跳过，不要让一个坏值拦住整轮播报
    if (deny.has(s)) continue;
    if (out.includes(s)) continue;
    out.push(s);
  }
  return out.map((qq) => `private:${qq}`);
}

/**
 * 走一轮播报：给每个对象发一条文案，失败的等 gapMs 再整轮重试，直到全部成功或次数用尽。
 *
 * @param {'online'|'offline'} kind
 * @param {object} deps
 * @param {object} deps.cfg               完整配置（读 announce / allow / deny）
 * @param {(key:string, text:string)=>Promise<any>} deps.sendToQQ  桥接的发送函数（返回落盘后的 promise）
 * @param {(key:string)=>boolean} deps.lastSucceeded  上一批是否全部成功（sendToQQ 把失败吞成日志，
 *        必须靠它判断，否则会"报成功其实没发出去"）
 * @param {(ms:number)=>Promise<any>} deps.sleep
 * @param {(...a:any[])=>void} [deps.log]
 * @returns {Promise<{ok:boolean, text?:string, targets:string[], failed:string[], attempts?:number, skipped?:string}>}
 */
export async function announceLifecycle(kind, { cfg, sendToQQ, lastSucceeded, sleep, log = () => {} }) {
  const settings = announceSettings(cfg);
  if (!settings.enabled) return { ok: false, skipped: 'disabled', targets: [], failed: [] };

  const targets = announceTargets(cfg);
  if (!targets.length) {
    log('（播报：白名单里没有可播报的私聊对象，跳过）');
    return { ok: false, skipped: 'no-targets', targets: [], failed: [] };
  }

  const offline = kind === 'offline';
  const text = offline ? settings.offline : settings.online;
  const label = offline ? '下线' : '上线';

  let failed = [];
  for (let attempt = 1; attempt <= settings.attempts; attempt++) {
    failed = [];
    for (const key of targets) {
      try {
        await sendToQQ(key, text);
        // sendToQQ 内部把失败吞成一行日志，必须再问一次"上一批到底成没成"。
        if (typeof lastSucceeded === 'function' && lastSucceeded(key) === false) failed.push(key);
      } catch (error) {
        failed.push(key);
        log(`播报「${text}」发给 ${key} 抛错：${error?.message ?? error}`);
      }
    }
    if (!failed.length) {
      log(`📣 ${label}播报完成：「${text}」已发给 ${targets.length} 位白名单私聊用户（${targets.join(', ')}）`);
      return { ok: true, text, targets, failed: [], attempts: attempt };
    }
    log(`⚠️ ${label}播报第 ${attempt}/${settings.attempts} 次未全部成功，失败 ${failed.length} 个（${failed.join(', ')}）`
      + (attempt < settings.attempts ? `，${Math.round(settings.gapMs / 1000)} 秒后重试` : ''));
    if (attempt < settings.attempts) await sleep(settings.gapMs);
  }
  return { ok: false, text, targets, failed, attempts: settings.attempts };
}
