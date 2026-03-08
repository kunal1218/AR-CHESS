from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import shlex
import shutil
from dataclasses import dataclass
from pathlib import Path


_BESTMOVE_PATTERN = re.compile(r"^bestmove\s+(\S+)")
_SCORE_PATTERN = re.compile(r"\bscore\s+(cp|mate)\s+(-?\d+)")


@dataclass(slots=True)
class AnalysisResult:
    bestmove: str
    evaluation: int
    mate_in: int | None


class StockfishTimeoutError(RuntimeError):
    """Raised when Stockfish does not return a bestmove before timeout."""


class StockfishEngine:
    def __init__(
        self,
        *,
        executable_path: str | None = None,
        max_depth: int = 18,
        logger: logging.Logger | None = None,
    ) -> None:
        self._executable_path = (executable_path or os.getenv("STOCKFISH_PATH") or "stockfish").strip()
        self._node_binary = (os.getenv("NODE_BINARY") or shutil.which("node") or "node").strip()
        self._bundled_script_path = (
            Path(__file__).resolve().parents[1] / "scripts" / "stockfish_query.mjs"
        )
        self._max_depth = max(1, max_depth)
        self._logger = logger or logging.getLogger("archess.stockfish")
        self._process: asyncio.subprocess.Process | None = None
        self._lock = asyncio.Lock()

    async def analyze_position(self, fen: str, depth: int) -> AnalysisResult:
        clamped_depth = max(1, min(depth, self._max_depth))

        async with self._lock:
            if self._should_use_bundled_engine():
                return await self._analyze_with_bundled_engine(fen, clamped_depth)

            await self._ensure_process()
            assert self._process is not None

            await self._send_line("isready")
            await self._wait_for_line("readyok", timeout_seconds=2.0)
            await self._send_line(f"position fen {fen}")
            await self._send_line(f"go depth {clamped_depth}")

            try:
                return await asyncio.wait_for(self._collect_result(), timeout=10.0)
            except asyncio.TimeoutError as exc:
                await self._handle_timeout()
                raise StockfishTimeoutError("Stockfish analysis timed out after 10 seconds.") from exc

    async def close(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return

        if process.returncode is None:
            try:
                await self._send_line("quit", process=process)
            except Exception:
                pass
            process.kill()
            await process.wait()

    async def _ensure_process(self) -> None:
        if self._process is not None and self._process.returncode is None:
            return

        command = shlex.split(self._executable_path)
        if not command:
            raise RuntimeError("STOCKFISH_PATH is empty.")

        self._process = await asyncio.create_subprocess_exec(
            *command,
            stdin=asyncio.subprocess.PIPE,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        self._logger.info("Stockfish process started path=%s", self._executable_path)

        await self._send_line("uci")
        await self._wait_for_line("uciok", timeout_seconds=4.0)
        await self._send_line("isready")
        await self._wait_for_line("readyok", timeout_seconds=4.0)

    def _should_use_bundled_engine(self) -> bool:
        if os.getenv("ARCHESS_FORCE_BUNDLED_STOCKFISH") == "1":
            return True

        command = shlex.split(self._executable_path)
        if not command:
            return True

        binary = command[0]
        if os.path.isabs(binary):
            return not os.path.exists(binary)

        return shutil.which(binary) is None

    async def _analyze_with_bundled_engine(self, fen: str, depth: int) -> AnalysisResult:
        if not self._bundled_script_path.exists():
            raise RuntimeError(
                f"Bundled Stockfish fallback script is missing at {self._bundled_script_path}."
            )

        process = await asyncio.create_subprocess_exec(
            self._node_binary,
            str(self._bundled_script_path),
            "--fen",
            fen,
            "--depth",
            str(depth),
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )

        try:
            stdout, stderr = await asyncio.wait_for(process.communicate(), timeout=12.0)
        except asyncio.TimeoutError as exc:
            process.kill()
            await process.wait()
            raise StockfishTimeoutError(
                "Bundled Stockfish analysis timed out after 12 seconds."
            ) from exc

        if process.returncode != 0:
            message = stderr.decode("utf-8", errors="ignore").strip() or stdout.decode(
                "utf-8", errors="ignore"
            ).strip()
            raise RuntimeError(message or "Bundled Stockfish analysis failed.")

        payload = json.loads(stdout.decode("utf-8"))
        bestmove = str(payload.get("bestmove") or "").strip()
        if not bestmove:
            raise RuntimeError("Bundled Stockfish analysis returned no bestmove.")

        mate_in_raw = payload.get("mate_in")
        return AnalysisResult(
            bestmove=bestmove,
            evaluation=int(payload.get("evaluation") or 0),
            mate_in=int(mate_in_raw) if mate_in_raw is not None else None,
        )

    async def _collect_result(self) -> AnalysisResult:
        last_evaluation = 0
        last_mate_in: int | None = None

        while True:
            line = await self._readline()
            if not line:
                raise RuntimeError("Stockfish exited before returning bestmove.")

            if line.startswith("info "):
                parsed = self._parse_score(line)
                if parsed is not None:
                    last_evaluation, last_mate_in = parsed
                continue

            bestmove_match = _BESTMOVE_PATTERN.match(line)
            if bestmove_match is None:
                continue

            bestmove = bestmove_match.group(1)
            return AnalysisResult(
                bestmove=bestmove,
                evaluation=last_evaluation,
                mate_in=last_mate_in,
            )

    def _parse_score(self, line: str) -> tuple[int, int | None] | None:
        match = _SCORE_PATTERN.search(line)
        if match is None:
            return None

        score_type, raw_value = match.groups()
        value = int(raw_value)

        if score_type == "cp":
            return value, None

        return (99999 if value > 0 else -99999), value

    async def _handle_timeout(self) -> None:
        try:
            await self._send_line("stop")
        except Exception:
            pass
        await self._restart_process()

    async def _restart_process(self) -> None:
        process = self._process
        self._process = None
        if process is None:
            return

        if process.returncode is None:
            process.kill()
            await process.wait()

    async def _wait_for_line(self, expected: str, *, timeout_seconds: float) -> None:
        while True:
            line = await asyncio.wait_for(self._readline(), timeout=timeout_seconds)
            if line == expected:
                return

    async def _readline(self) -> str:
        if self._process is None or self._process.stdout is None:
            raise RuntimeError("Stockfish process is not available.")

        raw_line = await self._process.stdout.readline()
        return raw_line.decode("utf-8", errors="ignore").strip()

    async def _send_line(
        self,
        line: str,
        *,
        process: asyncio.subprocess.Process | None = None,
    ) -> None:
        active_process = process or self._process
        if active_process is None or active_process.stdin is None:
            raise RuntimeError("Stockfish process is not available.")

        active_process.stdin.write(f"{line}\n".encode("utf-8"))
        await active_process.stdin.drain()
