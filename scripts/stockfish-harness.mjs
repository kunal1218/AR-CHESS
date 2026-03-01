import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { createRequire } from "node:module";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const repoRoot = path.resolve(__dirname, "..");
const enginePath = path.join(repoRoot, "ios", "ARChess", "Stockfish", "stockfish-nnue-16-single.js");
const wasmPath = path.join(repoRoot, "ios", "ARChess", "Stockfish", "stockfish-nnue-16-single.wasm");
const sampleFensPath = path.join(repoRoot, "scripts", "stockfish-sample-fens.json");
const require = createRequire(import.meta.url);

class RingBuffer {
  constructor(capacity) {
    this.capacity = Math.max(1, capacity);
    this.items = [];
  }

  push(item) {
    this.items.push(item);
    if (this.items.length > this.capacity) {
      this.items.splice(0, this.items.length - this.capacity);
    }
  }

  values() {
    return [...this.items];
  }
}

class StockfishHarnessError extends Error {
  constructor(message, diagnostics) {
    super(message);
    this.name = "StockfishHarnessError";
    this.diagnostics = diagnostics;
  }
}

function hashFen(fen) {
  return createHash("sha256").update(fen).digest("hex").slice(0, 12);
}

function validateFen(fen, { strict = false } = {}) {
  const fields = fen.trim().split(/\s+/);
  if (fields.length !== 6) {
    throw new Error("FEN must contain exactly 6 fields.");
  }

  const [placement, sideToMove, castling, enPassant, halfmove, fullmove] = fields;
  if (!["w", "b"].includes(sideToMove)) {
    throw new Error(`Invalid side-to-move field: ${sideToMove}`);
  }

  if (!/^(?:-|K?Q?k?q?)$/.test(castling)) {
    throw new Error(`Invalid castling rights field: ${castling}`);
  }

  if (!/^(?:-|[a-h][36])$/.test(enPassant)) {
    throw new Error(`Invalid en-passant field: ${enPassant}`);
  }

  if (!/^\d+$/.test(halfmove)) {
    throw new Error(`Invalid halfmove clock: ${halfmove}`);
  }

  if (!/^[1-9]\d*$/.test(fullmove)) {
    throw new Error(`Invalid fullmove number: ${fullmove}`);
  }

  const ranks = placement.split("/");
  if (ranks.length !== 8) {
    throw new Error(`Piece placement must contain 8 ranks. Found ${ranks.length}.`);
  }

  let whiteKings = 0;
  let blackKings = 0;
  const validPieces = new Set("prnbqkPRNBQK".split(""));

  ranks.forEach((rank, index) => {
    let squares = 0;
    for (const character of rank) {
      if (/\d/.test(character)) {
        const digit = Number(character);
        if (digit < 1 || digit > 8) {
          throw new Error(`Invalid FEN digit: ${character}`);
        }
        squares += digit;
        continue;
      }

      if (!validPieces.has(character)) {
        throw new Error(`Invalid FEN piece character: ${character}`);
      }

      squares += 1;
      if (character === "K") {
        whiteKings += 1;
      } else if (character === "k") {
        blackKings += 1;
      }

      if (strict && character.toLowerCase() === "p" && (index === 0 || index === 7)) {
        throw new Error(`Strict mode rejects pawns on rank ${8 - index}.`);
      }
    }

    if (squares !== 8) {
      throw new Error(`Rank ${8 - index} does not sum to 8 squares. Found ${squares}.`);
    }
  });

  if (whiteKings !== 1 || blackKings !== 1) {
    throw new Error(`Expected exactly one white king and one black king. Found white=${whiteKings}, black=${blackKings}.`);
  }

  return {
    fen: fen.trim(),
    sideToMove,
  };
}

function parseBestMove(bestMove) {
  return /^[a-h][1-8][a-h][1-8][nbrq]?$/.test(bestMove);
}

class InProcessStockfishController {
  constructor(config = {}) {
    this.config = {
      startupTimeoutMs: 4000,
      readyTimeoutMs: 1000,
      threads: 1,
      hashMb: 16,
      ...config,
    };
    this.engine = null;
    this.state = "INIT";
    this.readyWaiters = [];
    this.currentSearch = null;
    this.stdout = new RingBuffer(300);
    this.commands = new RingBuffer(50);
    this.requestCounter = 0;
    this.needsNewGame = true;
  }

  async init() {
    if (this.engine) {
      await this.waitUntilReady(this.config.readyTimeoutMs);
      return;
    }

    const stockfishFactoryFactory = require(enginePath);
    const StockfishFactory = stockfishFactoryFactory();
    this.engine = await StockfishFactory({
      locateFile(file) {
        return file.endsWith(".wasm") ? wasmPath : file;
      },
    });

    if (typeof this.engine.addMessageListener === "function") {
      this.engine.addMessageListener((line) => {
        this.handleLine(String(line));
      });
    } else if (typeof this.engine.onmessage !== "undefined") {
      this.engine.onmessage = (line) => {
        this.handleLine(String(line?.data ?? line));
      };
    } else {
      throw new Error("Bundled Stockfish did not expose a message listener API.");
    }

    this.state = "SENT_UCI";
    this.send("uci");
    await this.waitForLine("uciok", this.config.startupTimeoutMs, "Timed out waiting for uciok.");

    this.send("setoption name UCI_AnalyseMode value true");
    this.send(`setoption name Threads value ${this.config.threads}`);
    this.send(`setoption name Hash value ${this.config.hashMb}`);
    this.send("setoption name Ponder value false");
    this.send("isready");
    this.state = "WAITING_READY";
    await this.waitUntilReady(this.config.startupTimeoutMs);
  }

  async newGame() {
    await this.init();
    this.needsNewGame = true;
  }

  async analyzePosition(fen, options = {}) {
    const validated = validateFen(fen);
    await this.init();
    if (this.currentSearch) {
      await this.cancelCurrentSearch("superseded by a newer request");
    }

    if (this.needsNewGame) {
      this.needsNewGame = false;
      this.send("ucinewgame");
    }

    this.send("isready");
    this.state = "WAITING_READY";
    await this.waitUntilReady(this.config.readyTimeoutMs);

    const requestId = `cli-${++this.requestCounter}`;
    const movetimeMs = options.movetimeMs ?? 80;
    const hardTimeoutMs = options.hardTimeoutMs ?? Math.max(500, movetimeMs + 250);
    const debugDepth = options.debugDepth ?? null;
    const startedAt = Date.now();

    const resultPromise = new Promise((resolve, reject) => {
      const timeout = setTimeout(async () => {
        if (!this.currentSearch || this.currentSearch.id !== requestId) {
          return;
        }

        try {
          await this.cancelCurrentSearch("hard timeout");
        } catch (error) {
          reject(error);
          return;
        }

        reject(new StockfishHarnessError(`Timed out waiting for bestmove after ${hardTimeoutMs}ms.`, this.dumpDiagnostics(requestId, validated.fen)));
      }, hardTimeoutMs);

      this.currentSearch = {
        id: requestId,
        fen: validated.fen,
        resolve: (payload) => {
          clearTimeout(timeout);
          resolve(payload);
        },
        reject: (error) => {
          clearTimeout(timeout);
          reject(error);
        },
        scoreCp: null,
        mateIn: null,
        pv: [],
      };
    });

    this.state = "THINKING";
    this.send(`position fen ${validated.fen}`);
    if (debugDepth != null) {
      this.send(`go depth ${debugDepth}`);
    } else {
      this.send(`go movetime ${movetimeMs}`);
    }

    const result = await resultPromise;
    const durationMs = Date.now() - startedAt;
    if (!result.bestMove || result.bestMove === "(none)" || !parseBestMove(result.bestMove)) {
      throw new StockfishHarnessError("Stockfish returned an unparseable bestmove.", this.dumpDiagnostics(requestId, validated.fen));
    }

    return {
      requestId,
      fen: validated.fen,
      durationMs,
      bestMove: result.bestMove,
      scoreCp: result.scoreCp,
      mateIn: result.mateIn,
      pv: result.pv,
    };
  }

  async cancelCurrentSearch(reason) {
    const pending = this.currentSearch;
    if (!pending) {
      return;
    }

    this.currentSearch = null;
    pending.reject(new StockfishHarnessError(`Search cancelled: ${reason}.`, this.dumpDiagnostics(pending.id, pending.fen)));
    this.send("stop");
    this.send("isready");
    this.state = "WAITING_READY";
    await this.waitUntilReady(this.config.readyTimeoutMs);
  }

  handleLine(line) {
    this.stdout.push(line);

    if (line === "readyok") {
      this.state = "READY";
      const waiters = [...this.readyWaiters];
      this.readyWaiters = [];
      waiters.forEach((waiter) => waiter.resolve());
      return;
    }

    if (line.startsWith("info ") && this.currentSearch) {
      const cpMatch = line.match(/score cp (-?\d+)/);
      if (cpMatch) {
        this.currentSearch.scoreCp = Number(cpMatch[1]);
        this.currentSearch.mateIn = null;
      }

      const mateMatch = line.match(/score mate (-?\d+)/);
      if (mateMatch) {
        this.currentSearch.mateIn = Number(mateMatch[1]);
        this.currentSearch.scoreCp = null;
      }

      const pvMatch = line.match(/\spv\s(.+)/);
      if (pvMatch) {
        this.currentSearch.pv = pvMatch[1].trim().split(/\s+/).filter(Boolean);
      }

      return;
    }

    if (line.startsWith("bestmove ")) {
      const pending = this.currentSearch;
      this.currentSearch = null;
      this.state = "READY";
      if (!pending) {
        return;
      }

      pending.resolve({
        bestMove: line.trim().split(/\s+/)[1] ?? null,
        scoreCp: pending.scoreCp,
        mateIn: pending.mateIn,
        pv: pending.pv,
      });
    }
  }

  send(command) {
    if (!this.engine) {
      throw new Error("Stockfish engine is not initialized.");
    }

    this.commands.push(command);
    if (typeof this.engine.onCustomMessage === "function") {
      this.engine.onCustomMessage(command);
      return;
    }

    if (typeof this.engine.postMessage === "function") {
      this.engine.postMessage(command);
      return;
    }

    throw new Error("Stockfish engine command API is unavailable.");
  }

  async waitForLine(expectedLine, timeoutMs, message) {
    const startedAt = Date.now();
    while (Date.now() - startedAt <= timeoutMs) {
      if (this.stdout.values().includes(expectedLine)) {
        return;
      }
      await new Promise((resolve) => setTimeout(resolve, 10));
    }

    throw new StockfishHarnessError(message, this.dumpDiagnostics(null, null));
  }

  async waitUntilReady(timeoutMs) {
    if (this.state === "READY") {
      return;
    }

    await new Promise((resolve, reject) => {
      const waiter = {
        resolve: () => {
          clearTimeout(timeout);
          resolve();
        },
      };

      const timeout = setTimeout(() => {
        this.readyWaiters = this.readyWaiters.filter((candidate) => candidate !== waiter);
        reject(new StockfishHarnessError("Timed out waiting for readyok.", this.dumpDiagnostics(this.currentSearch?.id ?? null, this.currentSearch?.fen ?? null)));
      }, timeoutMs);

      this.readyWaiters.push(waiter);
    });
  }

  dumpDiagnostics(requestId, fen) {
    return [
      `state=${this.state}`,
      `request_id=${requestId ?? "-"}`,
      `fen_hash=${fen ? hashFen(fen) : "-"}`,
      "commands_sent:",
      ...this.commands.values().map((command) => `  > ${command}`),
      "engine_output:",
      ...this.stdout.values().slice(-100).map((line) => `  < ${line}`),
    ].join("\n");
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
    this.state = "CLOSED";
  }
}

async function loadSampleFens() {
  const raw = await readFile(sampleFensPath, "utf8");
  return JSON.parse(raw);
}

async function main() {
  const samples = await loadSampleFens();
  const controller = new InProcessStockfishController({
    threads: 1,
    hashMb: 16,
  });
  const movetimes = [50, 100, 200];
  let successes = 0;
  const failures = [];

  console.log(`Running Stockfish harness against ${samples.length} positions using ${path.relative(repoRoot, enginePath)}...`);

  try {
    await controller.init();
    for (const sample of samples) {
      await controller.newGame();
      for (const movetimeMs of movetimes) {
        try {
          const result = await controller.analyzePosition(sample.fen, {
            movetimeMs,
            hardTimeoutMs: Math.max(500, movetimeMs + 250),
          });
          successes += 1;
          console.log(
            `OK  [${sample.name}] movetime=${movetimeMs}ms bestmove=${result.bestMove} duration=${result.durationMs}ms score=${result.scoreCp ?? `mate ${result.mateIn ?? "?"}`}`
          );
        } catch (error) {
          failures.push({ sample, movetimeMs, error });
          console.error(`FAIL [${sample.name}] movetime=${movetimeMs}ms`);
          console.error(error instanceof StockfishHarnessError ? error.message : String(error));
          if (error instanceof StockfishHarnessError) {
            console.error(error.diagnostics);
          }
        }
      }
    }
  } finally {
    await controller.quit();
  }

  console.log(`\nCompleted ${successes} successful searches across ${samples.length * movetimes.length} attempts.`);
  if (failures.length > 0) {
    process.exitCode = 1;
    return;
  }

  console.log("All Stockfish harness checks passed.");
}

main().catch((error) => {
  console.error(error instanceof StockfishHarnessError ? error.message : error);
  if (error instanceof StockfishHarnessError) {
    console.error(error.diagnostics);
  }
  process.exitCode = 1;
});
