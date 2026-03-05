import sys
from pathlib import Path


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
