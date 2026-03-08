from __future__ import annotations

import asyncio
import os
import sys
from pathlib import Path


REPO_ROOT = Path(__file__).resolve().parents[2]
SERVER_APP_ROOT = REPO_ROOT / "server-app"
if str(SERVER_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_APP_ROOT))

from services.stockfish_engine import StockfishEngine  # noqa: E402


def test_stockfish_engine_falls_back_to_bundled_wasm_when_native_binary_is_missing() -> None:
    async def run() -> None:
        previous_force = os.environ.get("ARCHESS_FORCE_BUNDLED_STOCKFISH")
        os.environ["ARCHESS_FORCE_BUNDLED_STOCKFISH"] = "1"
        engine = StockfishEngine(executable_path="definitely-missing-stockfish-binary")
        try:
            result = await engine.analyze_position(
                "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
                8,
            )
        finally:
            await engine.close()
            if previous_force is None:
                os.environ.pop("ARCHESS_FORCE_BUNDLED_STOCKFISH", None)
            else:
                os.environ["ARCHESS_FORCE_BUNDLED_STOCKFISH"] = previous_force

        assert len(result.bestmove) >= 4
        assert isinstance(result.evaluation, int)

    asyncio.run(run())
