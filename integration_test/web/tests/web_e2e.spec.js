// X-05：Chromium（Playwright）下的 Web 端 E2E。
// 覆盖：令牌登录门禁、双端互发文本、刷新后历史恢复。
const fs = require('node:fs');
const path = require('node:path');
const { test, expect } = require('@playwright/test');
const { Stack, conversationIdOf } = require('../support/stack');

const VIEWPORT = { width: 430, height: 900 };

let stack;

test.describe.configure({ mode: 'serial' });

async function enableSemantics(page) {
  // Flutter Web 默认不生成语义树，需点亮 flt-semantics-placeholder 才会开启。
  // 桌面实现的占位元素是视口外 1x1，移动实现则铺满视口且要求点击落点距元素中心
  // 小于 1px；focus()+Enter 产生的 click 坐标为 (0,0)，在移动实现下偶发激活失败。
  // 直接在占位元素上派发带其中心坐标的 click：桌面按 target 命中，移动按坐标命中。
  const placeholder = page.locator('flt-semantics-placeholder');
  try {
    await placeholder.first().waitFor({ state: 'attached', timeout: 30000 });
  } catch (_) {
    // 语义树已开启时占位元素不存在。
  }
  for (let attempt = 0; attempt < 10; attempt++) {
    if ((await placeholder.count()) === 0) return;
    await page.evaluate(() => {
      const el = document.querySelector('flt-semantics-placeholder');
      if (!el) return;
      const rect = el.getBoundingClientRect();
      el.dispatchEvent(new MouseEvent('click', {
        bubbles: true,
        clientX: rect.left + rect.width / 2,
        clientY: rect.top + rect.height / 2,
      }));
    });
    await page.waitForTimeout(300);
  }
  if ((await placeholder.count()) !== 0) {
    throw new Error('无法启用 Flutter Web 语义树');
  }
}

// 启动服务检测门：CI 环境可能无法完成全部探测，用兜底按钮进入主界面。
async function dismissStartupGate(page) {
  const cont = page.getByRole('button', { name: /仍要进入/ }).first();
  try {
    await cont.waitFor({ state: 'visible', timeout: 8000 });
    await cont.click();
  } catch (_) {
    // 服务全部就绪时不会出现检测门。
  }
  await page.getByRole('tab', { name: '消息' }).waitFor({ state: 'attached', timeout: 20000 });
}

async function openApp(page, baseUrl, token) {
  const query = token ? `?token=${encodeURIComponent(token)}` : '';
  await page.goto(`${baseUrl}/${query}`, { waitUntil: 'load' });
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await enableSemantics(page);
  await dismissStartupGate(page);
}

async function newPage(browser) {
  const context = await browser.newContext({ viewport: VIEWPORT });
  const page = await context.newPage();
  page.on('console', (msg) => {
    if (msg.type() === 'error') {
      console.log('[browser]', msg.text());
    }
  });
  return { context, page };
}

// 预热：等待 DHT 收敛并确认单聊链路可用，避免首条 UI 消息受冷启动影响。
async function warmup() {
  const { ports, tokens } = stack;
  const text = '联调预热';
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

async function typeInto(page, field, text) {
  // Flutter Web 切换焦点时首个按键可能被上一个输入框的失焦流程吞掉，
  // 逐字符输入后校验回填值，缺失则补一次。
  await field.click();
  await page.waitForTimeout(300);
  await field.pressSequentially(text, { delay: 20 });
  const value = await field.inputValue().catch(() => text);
  if (value !== text) {
    await field.press('Control+A');
    await field.pressSequentially(text, { delay: 20 });
  }
}

test.beforeAll(async () => {
  const runDir = path.join(__dirname, '..', '.run', `pw-${Date.now()}`);
  fs.mkdirSync(runDir, { recursive: true });
  stack = new Stack(runDir);
  try {
    await stack.start();
    console.log(`E2E 账号：A=${stack.accountA.account_id} B=${stack.accountB.account_id}`);
    await warmup();
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

test('令牌登录：无令牌为离线空态，带令牌建立内核连接', async ({ browser }) => {
  const anonymous = await newPage(browser);
  const sockets = [];
  anonymous.page.on('websocket', (ws) => sockets.push(ws.url()));
  await openApp(anonymous.page, stack.url('webA'), '');
  // Flutter Web 会把空态文案合并进所在 group 的可访问名称，
  // 未必生成独立的文本节点，因此按可访问名称匹配而非 getByText。
  await expect(
    anonymous.page.getByRole('group', { name: /暂无会话，点击 \+ 发起聊天/ }),
  ).toBeVisible();
  expect(sockets).toHaveLength(0);
  await anonymous.context.close();

  const authed = await newPage(browser);
  const socketPromise = authed.page.waitForEvent('websocket', { timeout: 30000 });
  await openApp(authed.page, stack.url('webA'), stack.tokens.a);
  const socket = await socketPromise;
  expect(socket.url()).toContain('/ws');
  expect(socket.url()).toContain('token=');
  // 连上内核后预热会话以按钮形式呈现（含时间后缀），空态则可能仍在 group 名称里。
  await expect(
    authed.page.getByRole('button', { name: /联调预热/ }).or(
      authed.page.getByRole('group', { name: /暂无会话，点击 \+ 发起聊天/ }),
    ).first(),
  ).toBeVisible();
  await authed.context.close();
});

test('双端互发文本：A 端 UI 发送，B 端内核实时入库', async ({ browser }) => {
  const a = await newPage(browser);
  const page = a.page;
  await openApp(page, stack.url('webA'), stack.tokens.a);

  // warmup 已通过内核在 A↔B 间建立会话，直接点开该会话发送文本。
  // （Web 端「添加好友」现为好友申请制，需对方同意，不属于消息链路测试范围。）
  const chatRow = page.getByRole('button', { name: /联调预热/ });
  await expect(chatRow).toBeVisible({ timeout: 15000 });
  await chatRow.click();

  const message = `E2E 你好 ${Date.now()}`;
  const composer = page.getByRole('textbox', { name: '输入消息' });
  await composer.waitFor({ state: 'visible', timeout: 15000 });
  await typeInto(page, composer, message);
  await page.getByRole('button', { name: '发送', exact: true }).click();

  await expect(page.getByText(message).first()).toBeVisible();
  await stack.waitMessage(
    stack.ports.webB,
    stack.tokens.b,
    stack.accountB.account_id,
    stack.accountA.account_id,
    message,
    45000,
  );
  a.context.close();
});

test('刷新恢复：B 端刷新后仍能看到收到的消息', async ({ browser }) => {
  const { ports, tokens } = stack;
  const history = await stack.call(ports.webB, tokens.b, 'msg.list', {
    conversation_id: conversationIdOf(
      stack.accountA.account_id,
      stack.accountB.account_id,
    ),
    limit: 50,
  });
  const received = (history.items || []).filter((m) => m.direction === 'in' && m.text.startsWith('E2E 你好'));
  expect(received.length).toBeGreaterThan(0);
  const text = received[received.length - 1].text;
  const row = (page) => page.getByRole('button', { name: new RegExp(text) });

  const b = await newPage(browser);
  await openApp(b.page, stack.url('webB'), stack.tokens.b);
  await expect(row(b.page)).toBeVisible();
  await row(b.page).click();
  await expect(b.page.getByText(text).last()).toBeVisible();

  // 刷新后从本地库重新拉取会话与消息。
  await openApp(b.page, stack.url('webB'), stack.tokens.b);
  await expect(row(b.page)).toBeVisible();
  await row(b.page).click();
  await expect(b.page.getByText(text).last()).toBeVisible();
  b.context.close();
});
