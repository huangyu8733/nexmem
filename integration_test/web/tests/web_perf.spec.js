// P6-08：Web 端性能验收（冷启动到可发消息、聊天页滚动帧时间）。
// 复用 X-05 的本地联调栈（真实 bootstrap + 索引服务 + 双 webd），
// 通过 Chromium（本机 Chrome）度量首屏时序与滚动期间的 rAF 帧间隔。
const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const { Stack } = require('../support/stack');

// 与既有 E2E 一致使用移动端宽度（底部三 Tab 布局），
// 桌面三栏只在 `>= 720px` 生效，性能口径以同一套 UI 代码为准。
const VIEWPORT = { width: 430, height: 900 };
// 预置消息数：聊天页单页取 50 条，多写一些确保滚动区间足够。
const SEED_MESSAGES = 60;

let stack;
let lastText = '';

test.describe.configure({ mode: 'serial' });

async function enableSemantics(page) {
  const enable = page.getByRole('button', { name: 'Enable accessibility' });
  try {
    await enable.first().waitFor({ state: 'attached', timeout: 30000 });
    await enable.first().focus();
    await page.keyboard.press('Enter');
    await page.getByRole('tab', { name: '消息' }).waitFor({ state: 'attached', timeout: 20000 });
  } catch (_) {
    // 已开启语义树时占位按钮不存在。
  }
  await page.waitForTimeout(600);
}

async function typeInto(page, field, text) {
  await field.click();
  await page.waitForTimeout(300);
  await field.pressSequentially(text, { delay: 20 });
  const value = await field.inputValue().catch(() => text);
  if (value !== text) {
    await field.press('Control+A');
    await field.pressSequentially(text, { delay: 20 });
  }
}

// 预热直连：首条消息受 DHT 冷启动影响，不计入性能指标。
async function warmup() {
  const { ports, tokens } = stack;
  const text = '性能预热';
  const deadline = Date.now() + 90000;
  let lastError = '';
  while (Date.now() < deadline) {
    try {
      await stack.call(ports.webA, tokens.a, 'dm.sendText', {
        peer: stack.accountB.account_id,
        text,
      });
    } catch (err) {
      lastError = err.message;
      await new Promise((r) => setTimeout(r, 3000));
      continue;
    }
    try {
      await stack.waitMessage(
        ports.webB,
        tokens.b,
        stack.accountB.account_id,
        stack.accountA.account_id,
        text,
        10000,
      );
      return;
    } catch (err) {
      lastError = err.message;
    }
  }
  throw new Error(`双端单聊预热失败：${lastError}`);
}

// 读取当前语义树里可见的消息编号（Flutter 只把视口内节点放进语义树）。
async function visibleMessages(page) {
  return page.evaluate(() => {
    const host = document.querySelector('flt-semantics-host');
    if (!host) {
      return [];
    }
    const text = host.innerText || '';
    const found = new Set();
    for (const match of text.matchAll(/性能消息 (\d+)/g)) {
      found.add(Number(match[1]));
    }
    if (text.includes('性能探针')) {
      found.add(-1);
    }
    return [...found].sort((a, b) => a - b);
  });
}

function sameRange(a, b) {
  return a.length === b.length && a.every((v, i) => v === b[i]);
}

// 在持续滚动期间采集 rAF 帧间隔；先探测哪个滚轮方向能让可见区间变化。
async function sampleScrollFrames(page) {
  const viewport = page.viewportSize();
  await page.mouse.move(viewport.width * 0.55, viewport.height * 0.5);

  const before = await visibleMessages(page);
  await page.mouse.wheel(0, 220);
  await page.waitForTimeout(400);
  let direction = 220;
  let moved = !sameRange(before, await visibleMessages(page));
  if (!moved) {
    direction = -220;
    await page.mouse.wheel(0, -220);
    await page.waitForTimeout(400);
    moved = !sameRange(before, await visibleMessages(page));
  }

  const sampling = page.evaluate(async () => {
    const deltas = [];
    await new Promise((resolve) => {
      let last = performance.now();
      const end = last + 2500;
      const tick = (now) => {
        deltas.push(now - last);
        last = now;
        if (now < end) {
          requestAnimationFrame(tick);
        } else {
          resolve();
        }
      };
      requestAnimationFrame(tick);
    });
    return deltas;
  });
  // 来回滚动，覆盖两个方向的列表构建。
  for (let i = 0; i < 40; i += 1) {
    await page.mouse.wheel(0, i < 20 ? direction : -direction);
    await page.waitForTimeout(60);
  }
  return { deltas: await sampling, moved };
}

function percentile(sorted, ratio) {
  const index = Math.min(sorted.length - 1, Math.floor(ratio * sorted.length));
  return sorted[index];
}

test.beforeAll(async () => {
  const runDir = path.join(__dirname, '..', '.run', `perf-${Date.now()}`);
  fs.mkdirSync(runDir, { recursive: true });
  stack = new Stack(runDir);
  try {
    await stack.start();
    await warmup();
    const { ports, tokens } = stack;
    for (let i = 1; i <= SEED_MESSAGES; i += 1) {
      lastText = `性能消息 ${i}`;
      await stack.call(ports.webA, tokens.a, 'dm.sendText', {
        peer: stack.accountB.account_id,
        text: lastText,
      });
    }
    await stack.waitMessage(
      ports.webB,
      tokens.b,
      stack.accountB.account_id,
      stack.accountA.account_id,
      lastText,
      45000,
    );
  } catch (err) {
    await stack.stop();
    throw err;
  }
});

test.afterAll(async () => {
  if (stack) {
    await stack.stop();
  }
});

test('冷启动到可发消息，并采集聊天页滚动帧时间', async ({ browser }) => {
  const context = await browser.newContext({ viewport: VIEWPORT });
  const page = await context.newPage();
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      console.log('[browser]', msg.text());
    }
  });

  // 冷启动：从导航开始到 WebSocket 建连、会话列表可见、聊天页可输入。
  const socketPromise = page.waitForEvent('websocket', { timeout: 60000 });
  const t0 = Date.now();
  await page.goto(`${stack.url('webA')}/?token=${encodeURIComponent(stack.tokens.a)}`, {
    waitUntil: 'load',
  });
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await socketPromise;
  const wsMs = Date.now() - t0;

  console.log(`[perf] flutter-view ${Date.now() - t0}ms`);
  await enableSemantics(page);
  console.log(`[perf] semantics ${Date.now() - t0}ms`);
  const row = page.getByRole('button', { name: new RegExp(lastText) });
  await expect(row).toBeVisible({ timeout: 60000 });
  console.log(`[perf] row ${Date.now() - t0}ms`);
  const uiMs = Date.now() - t0;

  await row.click();
  const composer = page.getByRole('textbox', { name: '输入消息' });
  await composer.waitFor({ state: 'visible', timeout: 20000 });
  const sendableMs = Date.now() - t0;

  // 可发消息的功能校验：UI 发出的消息要对端内核真实入库。
  const probe = `性能探针 ${Date.now()}`;
  await typeInto(page, composer, probe);
  await page.getByRole('button', { name: '发送' }).click();
  await expect(page.getByText(probe).first()).toBeVisible();
  await stack.waitMessage(
    stack.ports.webB,
    stack.tokens.b,
    stack.accountB.account_id,
    stack.accountA.account_id,
    probe,
    45000,
  );

  // 采集滚动帧时间，并确认滚轮确实改变了聊天页可见的消息区间。
  const { deltas: frames, moved } = await sampleScrollFrames(page);
  const sorted = [...frames].sort((a, b) => a - b);
  const p95 = percentile(sorted, 0.95);
  const max = sorted[sorted.length - 1];
  const jank = frames.filter((d) => d > 32).length;
  const jankRatio = frames.length === 0 ? 1 : jank / frames.length;

  console.log(
    [
      `WEB_PERF_COLD_START_WS_MS=${wsMs}`,
      `WEB_PERF_COLD_START_UI_MS=${uiMs}`,
      `WEB_PERF_COLD_START_SENDABLE_MS=${sendableMs}`,
      `WEB_PERF_SCROLL_FRAMES=${frames.length}`,
      `WEB_PERF_SCROLL_P50_MS=${percentile(sorted, 0.5).toFixed(2)}`,
      `WEB_PERF_SCROLL_P95_MS=${p95.toFixed(2)}`,
      `WEB_PERF_SCROLL_MAX_MS=${max.toFixed(2)}`,
      `WEB_PERF_SCROLL_JANK_FRAMES=${jank}`,
      `WEB_PERF_SCROLL_MOVED=${moved}`,
    ].join('\n'),
  );

  // 冷启动：传输就绪（内核可用）应稳定 < 3s；
  // 到可发消息的时间额外包含无障碍注入（约 700ms）与一次点击，作为观测值记录。
  expect(wsMs, 'WebSocket 建连应在 3s 内').toBeLessThan(3000);
  expect(sendableMs, '冷启动到可发消息作为观测指标，不应超过 6s').toBeLessThan(6000);
  expect(moved, '滚轮应改变聊天页可见消息区间').toBe(true);
  expect(frames.length, '滚动采样应覆盖足够帧数').toBeGreaterThan(60);
  expect(jankRatio, '滚动期间长帧占比应低于 10%').toBeLessThan(0.1);

  await context.close();
});
