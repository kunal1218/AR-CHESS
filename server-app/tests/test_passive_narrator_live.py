import asyncio
import sys
from pathlib import Path

import pytest


SERVER_APP_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_APP_ROOT))

from services.passive_narrator_live import PassiveNarratorLiveSession  # noqa: E402


class DummyFrontendSocket:
    def __init__(self) -> None:
        self.messages: list[str] = []

    async def accept(self) -> None:
        return None

    async def receive_text(self) -> str:
        raise RuntimeError("receive_text should not be called in this test")

    async def send_text(self, data: str) -> None:
        self.messages.append(data)


class ClosedFrontendSocket(DummyFrontendSocket):
    async def send_text(self, data: str) -> None:
        raise RuntimeError('Cannot call "send" once a close message has been sent.')


def test_wait_until_gemini_ready_raises_last_error_immediately() -> None:
    session = PassiveNarratorLiveSession(frontend_socket=DummyFrontendSocket())

    async def fake_connect() -> None:
        session._last_error_message = "Gemini passive narrator connect failed: API key expired."

    session._connect_gemini = fake_connect  # type: ignore[method-assign]

    with pytest.raises(RuntimeError, match="API key expired"):
        asyncio.run(session._wait_until_gemini_ready())


def test_send_frontend_ignores_closed_socket_runtime_error() -> None:
    session = PassiveNarratorLiveSession(frontend_socket=ClosedFrontendSocket())

    asyncio.run(session._send_frontend({"type": "status", "state": "error"}))

    assert session._closing is True
