from types import SimpleNamespace
import sys
from pathlib import Path

from websockets.protocol import State


SERVER_APP_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_APP_ROOT))

from services.gemini_live import GeminiLiveClient  # noqa: E402


def test_build_state_narrative_text_includes_fen_history_and_query() -> None:
    client = GeminiLiveClient(
        api_key="test-key",
        model="models/test",
        system_prompt="test",
    )

    packet = client._build_state_narrative_text(  # noqa: SLF001
        "Assess the position for the next player.",
        metadata={
            "current_fen": "8/8/8/8/8/8/8/8 w - - 0 1",
            "recent_history": "14... Nf6 15. O-O",
        },
    )

    assert packet == (
        "Current FEN: 8/8/8/8/8/8/8/8 w - - 0 1 | "
        "Recent Sequence: 14... Nf6 15. O-O | "
        "User Query: Assess the position for the next player."
    )


def test_build_state_narrative_text_omits_missing_history() -> None:
    client = GeminiLiveClient(
        api_key="test-key",
        model="models/test",
        system_prompt="test",
    )

    packet = client._build_state_narrative_text(  # noqa: SLF001
        "Find the main idea.",
        metadata={
            "current_fen": "8/8/8/8/8/8/8/8 w - - 0 1",
        },
    )

    assert packet == (
        "Current FEN: 8/8/8/8/8/8/8/8 w - - 0 1 | "
        "User Query: Find the main idea."
    )


def test_default_ws_url_targets_v1beta() -> None:
    assert GeminiLiveClient.DEFAULT_WS_URL.endswith(
        "google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent"
    )


def test_build_setup_payload_uses_live_camel_case_fields() -> None:
    client = GeminiLiveClient(
        api_key="test-key",
        model="models/test",
        system_prompt="System prompt",
        generation_config={"temperature": 0.5},
    )

    payload = client._build_setup_payload()  # noqa: SLF001

    assert payload == {
        "setup": {
            "model": "models/test",
            "generationConfig": {"temperature": 0.5},
            "systemInstruction": {
                "parts": [{"text": "System prompt"}],
            },
        }
    }


def test_build_client_content_payload_uses_live_camel_case_fields() -> None:
    client = GeminiLiveClient(
        api_key="test-key",
        model="models/test",
        system_prompt="test",
    )

    payload = client._build_client_content_payload(  # noqa: SLF001
        "Current FEN: test",
        turn_complete=True,
    )

    assert payload == {
        "clientContent": {
            "turns": [
                {
                    "role": "user",
                    "parts": [{"text": "Current FEN: test"}],
                }
            ],
            "turnComplete": True,
        }
    }


def test_is_socket_open_supports_websockets16_state() -> None:
    client = GeminiLiveClient(
        api_key="test-key",
        model="models/test",
        system_prompt="test",
    )
    client._ws = SimpleNamespace(state=State.OPEN)  # noqa: SLF001

    assert client._is_socket_open() is True  # noqa: SLF001


def test_is_terminal_error_treats_expired_api_key_close_reason_as_terminal() -> None:
    client = GeminiLiveClient(
        api_key="test-key",
        model="models/test",
        system_prompt="test",
    )

    assert client._is_terminal_error(  # noqa: SLF001
        "received 1007 (invalid frame payload data) API key expired"
    )
