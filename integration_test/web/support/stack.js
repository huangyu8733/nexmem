// 本地联调栈（X-05）：bootstrap + 索引服务 + 两个 nexmem-webd 内核实例。
// 全部通过 bin/ 下的真实二进制启动，浏览器只经 WebSocket 接入各自内核。
const { spawn } = require('node:child_process');
const fs = require('node:fs');
const net = require('node:net');
const path = require('node:path');
const WebSocket = require('ws');

const ROOT = path.resolve(__dirname, '..', '..', '..');
const EXE = process.platform === 'win32' ? '.exe' : '';
const BIN = (name) => path.join(ROOT, 'bin', `${name}${EXE}`);
const STATIC_DIR = path.join(ROOT, 'app', 'build', 'web');

function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function waitPort(port, timeoutMs = 30000) {
  const deadline = Date.now() + timeoutMs;
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const socket = net.connect({ host: '127.0.0.1', port }, () => {
        socket.destroy();
        resolve();
      });
      socket.on('error', () => {
        socket.destroy();
        if (Date.now() > deadline) {
          reject(new Error(`端口 ${port} 在 ${timeoutMs}ms 内未就绪`));
          return;
        }
        setTimeout(attempt, 200);
      });
    };
    attempt();
  });
}

async function waitHttp(url, timeoutMs = 60000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    try {
      const res = await fetch(url);
      if (res.ok) {
        return;
      }
    } catch (_) {
      // 未就绪，继续重试。
    }
    await wait(200);
  }
  throw new Error(`${url} 在 ${timeoutMs}ms 内未就绪`);
}

class Process {
  constructor(name, command, args, runDir) {
    this.name = name;
    this.logPath = path.join(runDir, `${name}.log`);
    this.log = fs.createWriteStream(this.logPath, { flags: 'a' });
    this.lines = [];
    this.child = spawn(command, args, {
      cwd: ROOT,
      windowsHide: true,
      stdio: ['ignore', 'pipe', 'pipe'],
    });
    const collect = (chunk) => {
      this.log.write(chunk);
      for (const line of chunk.toString('utf8').split(/\r?\n/)) {
        if (line.trim() === '') {
          continue;
        }
        this.lines.push(line);
        if (this.lines.length > 200) {
          this.lines.shift();
        }
        if (this.onLine) {
          this.onLine(line);
        }
      }
    };
    this.child.stdout.on('data', collect);
    this.child.stderr.on('data', collect);
    this.child.on('exit', (code, signal) => {
      this.exitCode = code;
      this.log.write(`\n[exit] code=${code} signal=${signal}\n`);
      if (process.env.NEXMEM_E2E_DEBUG === '1') {
        console.error(`[proc exit] ${this.name} code=${code} signal=${signal}`);
      }
    });
  }

  async stop() {
    if (this.exitCode !== undefined) {
      return;
    }
    if (process.platform === 'win32') {
      // Windows 下直接 taskkill 进程树，避免等待退出事件超时导致残留。
      await new Promise((resolve) => {
        const killer = spawn('taskkill', ['/pid', String(this.child.pid), '/t', '/f'], {
          windowsHide: true,
        });
        killer.on('exit', resolve);
        killer.on('error', resolve);
      });
    } else {
      this.child.kill();
    }
    const deadline = Date.now() + 3000;
    while (this.exitCode === undefined && Date.now() < deadline) {
      await wait(50);
    }
    this.log.end();
  }
}

function freePort() {
  return new Promise((resolve, reject) => {
    const server = net.createServer();
    server.unref();
    server.on('error', reject);
    server.listen(0, '127.0.0.1', () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

class Stack {
  constructor(runDir) {
    this.runDir = runDir;
    this.processes = [];
    this.ports = {};
    this.tokens = { a: 'e2e-token-a', b: 'e2e-token-b' };
  }

  url(name) {
    return `http://127.0.0.1:${this.ports[name]}`;
  }

  async start() {
    if (!fs.existsSync(path.join(STATIC_DIR, 'index.html'))) {
      throw new Error(`缺少 Flutter Web 产物：${STATIC_DIR}，请先执行 flutter build web --release`);
    }
    for (const item of ['nexmem-bootstrap', 'nexmem-directory', 'nexmem-webd']) {
      if (!fs.existsSync(BIN(item))) {
        throw new Error(`缺少二进制 ${BIN(item)}，请先执行 go build -o bin/...`);
      }
    }
    // 每轮使用随机空闲端口，避免上一轮 TIME_WAIT 或残留进程导致 bind 冲突。
    for (const name of ['bootstrap', 'directory', 'webA', 'webB']) {
      this.ports[name] = await freePort();
    }

    // 1) bootstrap：stdout 输出一行 JSON 提供对外地址。
    const bootstrap = new Process(
      'bootstrap',
      BIN('nexmem-bootstrap'),
      [
        '-listen', `/ip4/127.0.0.1/tcp/${this.ports.bootstrap}`,
        '-id', path.join(this.runDir, 'bootstrap.key'),
      ],
      this.runDir,
    );
    this.processes.push(bootstrap);
    const bootstrapAddr = await new Promise((resolve, reject) => {
      const timer = setTimeout(
        () => reject(new Error(`bootstrap 未输出地址：\n${bootstrap.lines.join('\n')}`)),
        30000,
      );
      bootstrap.onLine = (line) => {
        if (!line.trim().startsWith('{')) {
          return;
        }
        try {
          const info = JSON.parse(line);
          const addr = (info.addrs || []).find((a) => a.includes('/tcp/'));
          if (addr) {
            clearTimeout(timer);
            resolve(addr);
          }
        } catch (_) {
          // 忽略日志行。
        }
      };
    });

    // 2) 索引服务：提供公开档案，供双端按账号解析设备地址。
    const directory = new Process(
      'directory',
      BIN('nexmem-directory'),
      ['-addr', `127.0.0.1:${this.ports.directory}`, '-db', path.join(this.runDir, 'directory.db')],
      this.runDir,
    );
    this.processes.push(directory);
    await waitPort(this.ports.directory);

    this.bootstrapAddr = bootstrapAddr;

    // 3) 两个 Web 内核：同一 bootstrap + 同一索引服务，账号各自独立。
    this.webA = await this.startWebNode('a', this.ports.webA, 'node-a', 'E2E-A');
    this.webB = await this.startWebNode('b', this.ports.webB, 'node-b', 'E2E-B');

    this.accountA = await this.call(this.ports.webA, this.tokens.a, 'account.me');
    this.accountB = await this.call(this.ports.webB, this.tokens.b, 'account.me');
  }

  // startWebNode 以指定端口与数据目录拉起一个 Web 内核实例。
  async startWebNode(side, port, dataDir, displayName) {
    const proc = new Process(
      `web-${side}`,
      BIN('nexmem-webd'),
      [
        '-addr', `127.0.0.1:${port}`,
        '-token', this.tokens[side],
        '-static', STATIC_DIR,
        '-data-dir', path.join(this.runDir, dataDir),
        '-display-name', displayName,
        '-bootstraps', this.bootstrapAddr,
        '-directory', this.url('directory'),
      ],
      this.runDir,
    );
    this.processes.push(proc);
    await waitPort(port);
    await waitHttp(`http://127.0.0.1:${port}/healthz`);
    if (proc.exitCode !== undefined) {
      throw new Error(`${proc.name} 启动失败：\n${proc.lines.join('\n')}`);
    }
    return proc;
  }

  // restartWebNode 强制杀掉一端（等价用户杀进程），复用同一数据目录与原端口重启，
  // 返回重启后的 account.me，供门禁用例校验身份与历史是否完整。
  // 复用原端口可保持多地址不变，避免对端 DHT 缓存指向旧端口造成误判。
  async restartWebNode(side, timeoutMs = 60000) {
    const field = side === 'a' ? 'webA' : 'webB';
    const dataDir = side === 'a' ? 'node-a' : 'node-b';
    const displayName = side === 'a' ? 'E2E-A' : 'E2E-B';
    await this[field].stop();
    this[field] = await this.startWebNode(side, this.ports[field], dataDir, displayName);
    const deadline = Date.now() + timeoutMs;
    let lastError = '';
    while (Date.now() < deadline) {
      try {
        return await this.call(this.ports[field], this.tokens[side], 'account.me');
      } catch (err) {
        lastError = err.message;
        await wait(500);
      }
    }
    throw new Error(`重启后的内核 ${timeoutMs}ms 内未就绪：${lastError}`);
  }

  async stop() {
    for (const proc of [...this.processes].reverse()) {
      await proc.stop();
    }
  }

  // call 直接经 WebSocket 调内核方法，用于准备数据与断言。
  call(port, token, method, params = undefined, timeoutMs = 30000) {
    return new Promise((resolve, reject) => {
      const ws = new WebSocket(`ws://127.0.0.1:${port}/ws?token=${encodeURIComponent(token)}`);
      const timer = setTimeout(() => {
        ws.close();
        reject(new Error(`调用 ${method} 超时`));
      }, timeoutMs);
      ws.on('open', () => {
        ws.send(JSON.stringify({ id: 1, method, params }));
      });
      ws.on('message', (raw) => {
        let msg;
        try {
          msg = JSON.parse(raw.toString('utf8'));
        } catch (_) {
          return;
        }
        if (msg.id !== 1) {
          return;
        }
        clearTimeout(timer);
        ws.close();
        if (msg.ok) {
          resolve(msg.data || {});
        } else {
          reject(new Error(`${method} 失败：${JSON.stringify(msg.error)}`));
        }
      });
      ws.on('error', (err) => {
        clearTimeout(timer);
        reject(err);
      });
    });
  }

  // waitMessage 轮询目标账号的消息历史，直到命中指定正文。
  async waitMessage(port, token, selfAccount, peerAccount, text, timeoutMs = 45000) {
    const conversationId = conversationIdOf(selfAccount, peerAccount);
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      try {
        const data = await this.call(port, token, 'msg.list', {
          conversation_id: conversationId,
          limit: 50,
        });
        if ((data.items || []).some((m) => m.text === text)) {
          return data;
        }
      } catch (_) {
        // 尚未建立会话，继续等待。
      }
      await wait(500);
    }
    throw new Error(`等待消息「${text}」超时`);
  }
}

// conversationIdOf 与内核 `dm.ConversationID` 同构：两端账号十六进制升序拼接。
function conversationIdOf(a, b) {
  const left = a.toLowerCase();
  const right = b.toLowerCase();
  return left < right ? `dm:${left}|${right}` : `dm:${right}|${left}`;
}

module.exports = { Stack, ROOT, STATIC_DIR, conversationIdOf };
