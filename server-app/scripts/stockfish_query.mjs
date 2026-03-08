import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..", "..");
const enginePath = path.join(repoRoot, "ios", "ARChess", "Stockfish", "stockfish-nnue-16-single.js");
const wasmPath = path.join(repoRoot, "ios", "ARChess", "Stockfish", "stockfish-nnue-16-single.wasm");
const require = createRequire(import.meta.url);

class QueryController {
  constructor() {
    this.engine = null;
    this.state = "INIT";
    this.readyWaiters = [];
    this.pendingSearch = null;
    this.recentLines = [];
    this.lineWaiters = [];
  }

  async init() {
    if (this.engine) {
      await this.waitUntilReady(1500);
      return;
    }

    const stockfishFactoryFactory = require(enginePath);
    const stockfishFactory = stockfishFactoryFactory();
    this.engine = await stockfishFactory({
      locateFile(file) {
        return file.endsWith(".wasm") ? wasmPath : file;
      },
    });

    const onLine = (line) => this.handleLine(String(line?.data ?? line));
    if (typeof this.engine.addMessageListener === "function") {
      this.engine.addMessageListener(onLine);
    } else if ("onmessage" in this.engine) {
      this.engine.onmessage = onLine;
    } else {
      throw new Error("Bundled Stockfish did not expose a message listener API.");
    }

    this.send("uci");
    await this.waitForLine("uciok", 4000);
    this.send("setoption name UCI_AnalyseMode value true");
    this.send("setoption name Threads value 1");
    this.send("setoption name Hash value 16");
    this.send("setoption name Ponder value false");
    this.state = "WAITING_READY";
    this.send("isready");
    await this.waitUntilReady(4000);
  }

  async analyzePosition(fen, depth) {
    await this.init();
    this.send("ucinewgame");
    this.state = "WAITING_READY";
    this.send("isready");
    await this.waitUntilReady(1500);

    const resultPromise = new Promise((resolve, reject) => {
      this.pendingSearch = {
        resolve,
        reject,
        scoreCp: 0,
        mateIn: null,
      };
    });

    this.send(`position fen ${fen}`);
    this.send(`go depth ${depth}`);
    const result = await resultPromise;

    return {
      bestmove: result.bestMove,
      evaluation: result.mateIn == null ? result.scoreCp : (result.mateIn > 0 ? 99999 : -99999),
      mate_in: result.mateIn,
    };
  }

  handleLine(line) {
    this.recentLines.push(line);
    if (this.recentLines.length > 200) {
      this.recentLines.splice(0, this.recentLines.length - 200);
    }
    this.resolveLineWaiters(line);

    if (line === "readyok") {
      this.state = "READY";
      const waiters = [...this.readyWaiters];
      this.readyWaiters = [];
      waiters.forEach((resolve) => resolve());
      return;
    }

    if (line.startsWith("info ") && this.pendingSearch) {
      const cpMatch = line.match(/score cp (-?\d+)/);
      if (cpMatch) {
        this.pendingSearch.scoreCp = Number(cpMatch[1]);
        this.pendingSearch.mateIn = null;
      }

      const mateMatch = line.match(/score mate (-?\d+)/);
      if (mateMatch) {
        this.pendingSearch.mateIn = Number(mateMatch[1]);
      }
      return;
    }

    if (line.startsWith("bestmove ") && this.pendingSearch) {
      const pending = this.pendingSearch;
      this.pendingSearch = null;
      pending.resolve({
        bestMove: line.trim().split(/\s+/)[1] ?? "",
        scoreCp: pending.scoreCp,
        mateIn: pending.mateIn,
      });
    }
  }

  send(command) {
    if (!this.engine) {
      throw new Error("Bundled Stockfish engine is not initialized.");
    }

    if (typeof this.engine.onCustomMessage === "function") {
      this.engine.onCustomMessage(command);
      return;
    }

    if (typeof this.engine.postMessage === "function") {
      this.engine.postMessage(command);
      return;
    }

    throw new Error("Bundled Stockfish engine command API is unavailable.");
  }

  async waitForLine(expectedLine, timeoutMs) {
    if (this.recentLines.includes(expectedLine)) {
      return;
    }

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.lineWaiters = this.lineWaiters.filter((waiter) => waiter !== waiterRecord);
        reject(new Error(`Timed out waiting for ${expectedLine}.`));
      }, timeoutMs);

      const waiterRecord = {
        expectedLine,
        resolve: () => {
          clearTimeout(timeout);
          resolve();
        },
      };

      this.lineWaiters.push(waiterRecord);
    });
  }

  async waitUntilReady(timeoutMs) {
    if (this.state === "READY") {
      return;
    }

    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => {
        this.readyWaiters = this.readyWaiters.filter((candidate) => candidate !== resolver);
        reject(new Error("Timed out waiting for readyok."));
      }, timeoutMs);

      const resolver = () => {
        clearTimeout(timeout);
        resolve();
      };

      this.readyWaiters.push(resolver);
    });
  }

  resolveLineWaiters(line) {
    const matchingWaiters = this.lineWaiters.filter((waiter) => waiter.expectedLine === line);
    if (matchingWaiters.length === 0) {
      return;
    }

    this.lineWaiters = this.lineWaiters.filter((waiter) => waiter.expectedLine !== line);
    matchingWaiters.forEach((waiter) => waiter.resolve());
  }

  async quit() {
    if (!this.engine) {
      return;
    }
    this.send("quit");
    if (typeof this.engine.terminate === "function") {
      this.engine.terminate();
    }
    this.engine = null;
  }
}

function parseArgs(argv) {
  const args = new Map();
  for (let index = 0; index < argv.length; index += 1) {
    const token = argv[index];
    if (!token.startsWith("--")) {
      continue;
    }
    args.set(token.slice(2), argv[index + 1] ?? "");
    index += 1;
  }
  return args;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const fen = String(args.get("fen") ?? "").trim();
  const depth = Math.max(1, Number.parseInt(String(args.get("depth") ?? "15"), 10) || 15);
  if (!fen) {
    throw new Error("Missing required --fen argument.");
  }

  const controller = new QueryController();
  try {
    const result = await controller.analyzePosition(fen, depth);
    process.stdout.write(JSON.stringify(result));
  } finally {
    await controller.quit();
  }
}

main().catch((error) => {
  const message = error instanceof Error ? error.message : String(error);
  process.stderr.write(`${message}\n`);
  process.exitCode = 1;
});
