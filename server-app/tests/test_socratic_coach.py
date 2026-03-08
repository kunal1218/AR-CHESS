import asyncio
import sys
from pathlib import Path


SERVER_APP_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_APP_ROOT))

from services.move_parser import parse_natural_move  # noqa: E402
from services.socratic_coach import (  # noqa: E402
    GameStateStore,
    SocraticCoachSession,
    build_socratic_system_prompt,
    build_context_update_text,
    handle_analyze_hypothetical,
    sanitize_model_narration_text,
)
from services.stockfish_engine import AnalysisResult  # noqa: E402


def test_parse_natural_move_returns_uci_for_unambiguous_knight_move() -> None:
    fen = "4k3/8/8/8/8/2N5/8/4K3 w - - 0 1"

    assert parse_natural_move("Knight to d5", fen) == "c3d5"


def test_parse_natural_move_returns_none_for_ambiguous_move() -> None:
    fen = "4k3/8/8/8/8/8/3N1N2/6K1 w - - 0 1"

    assert parse_natural_move("Knight to e4", fen) is None


def test_parse_natural_move_returns_none_for_illegal_move() -> None:
    fen = "4k3/8/8/8/8/2N5/8/4K3 w - - 0 1"

    assert parse_natural_move("Knight to h8", fen) is None


def test_game_state_store_apply_move_updates_fen_and_san_history() -> None:
    store = GameStateStore()

    store.apply_move("e2e4")
    snapshot = store.get_snapshot()

    assert snapshot.fen == "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
    assert snapshot.move_history == ["e4"]
    assert snapshot.active_color == "b"
    assert snapshot.moves_played == 1


def test_context_update_text_uses_authoritative_store_snapshot() -> None:
    store = GameStateStore()
    store.apply_move("e2e4")
    snapshot = store.get_snapshot()

    packet = build_context_update_text(snapshot)

    assert "Current FEN: rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1" in packet
    assert "Move history: e4" in packet
    assert "Active color: b" in packet
    assert "Moves played: 1" in packet


def test_sanitize_model_narration_text_drops_internal_reasoning() -> None:
    raw_text = """
    **Defining Central Control**
    I'm focusing on defining central control as the key strategic element here.
    The user posed a broad strategic question, so I am crafting a response.
    I intend to conclude with a Socratic question.
    """

    assert sanitize_model_narration_text(raw_text) == ""


def test_sanitize_model_narration_text_preserves_player_facing_reply() -> None:
    raw_text = "You have more influence at the board's heart than your opponent right now. Which piece can support that pressure without drifting from your king?"

    assert sanitize_model_narration_text(raw_text) == raw_text


def test_sanitize_model_narration_text_strips_meta_segments_from_mixed_response() -> None:
    raw_text = (
        "I'm now structuring the response around central tension. "
        "You already have a foothold in the center, so now ask which piece can deepen it."
    )

    assert sanitize_model_narration_text(raw_text) == (
        "You already have a foothold in the center, so now ask which piece can deepen it."
    )


def test_sanitize_model_narration_text_caps_to_five_sentences() -> None:
    raw_text = (
        "You gave away the center. "
        "Your king is still uncastled. "
        "The loose bishop is asking to be hit. "
        "Your pieces are not helping each other. "
        "You must fix development now. "
        "Which piece can do that first?"
    )

    assert sanitize_model_narration_text(raw_text) == (
        "You gave away the center. Your king is still uncastled. "
        "The loose bishop is asking to be hit. Your pieces are not helping each other. "
        "You must fix development now."
    )


def test_build_socratic_system_prompt_appends_silky_personality() -> None:
    prompt = build_socratic_system_prompt("silky")

    assert "You are a Socratic chess coach." in prompt
    assert "calm, silky, confident delivery" in prompt
    assert "never exceed 5 short sentences" in prompt


def test_build_socratic_system_prompt_appends_fletcher_personality_without_silky_bias() -> None:
    prompt = build_socratic_system_prompt("fletcher")

    assert "ultra-intense chess coach" in prompt
    assert "Do not just roleplay anger. Teach through the anger." in prompt
    assert "calm and soothing" not in prompt


def test_help_request_prompt_explicitly_skips_hypothetical_tool() -> None:
    session = SocraticCoachSession(
        frontend_socket=object(),
        stockfish_engine=object(),
        api_key="test-key",
    )
    observed: dict[str, str] = {}

    async def fake_send_user_turn(text: str) -> None:
        observed["text"] = text

    session._send_user_turn = fake_send_user_turn  # type: ignore[method-assign]

    asyncio.run(session._handle_frontend_message({"type": "help_request"}))

    assert "do not call analyze_hypothetical_move for this reply" in observed["text"]


class FakeStockfishEngine:
    def __init__(self, evaluations: dict[str, AnalysisResult]) -> None:
        self._evaluations = evaluations

    async def analyze_position(self, fen: str, depth: int) -> AnalysisResult:
        assert depth == 15
        return self._evaluations[fen]


def test_handle_analyze_hypothetical_reads_fen_from_store_and_adjusts_delta_for_white() -> None:
    store = GameStateStore()
    current_fen = store.get_current_fen()
    hypothetical_fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
    engine = FakeStockfishEngine(
        {
            current_fen: AnalysisResult(bestmove="e2e4", evaluation=15, mate_in=None),
            hypothetical_fen: AnalysisResult(bestmove="c7c5", evaluation=110, mate_in=None),
        }
    )

    response = asyncio.run(
        handle_analyze_hypothetical(
            args={"player_move": "pawn to e4"},
            game_store=store,
            stockfish_engine=engine,
        )
    )

    assert response["original_eval"] == 15
    assert response["hypothetical_eval"] == 110
    assert response["eval_delta"] == 95
    assert response["opponent_best_reply_uci"] == "c7c5"
    assert response["opponent_best_reply_san"] == "c5"


def test_handle_analyze_hypothetical_adjusts_delta_for_black_to_move() -> None:
    store = GameStateStore()
    black_fen = "rnbqkbnr/pppppppp/8/8/4P3/8/PPPP1PPP/RNBQKBNR b KQkq - 0 1"
    store.replace_state(fen=black_fen, move_history=["e4"])
    hypothetical_fen = "rnbqkbnr/pppp1ppp/8/4p3/4P3/8/PPPP1PPP/RNBQKBNR w KQkq - 0 2"
    engine = FakeStockfishEngine(
        {
            black_fen: AnalysisResult(bestmove="c7c5", evaluation=50, mate_in=None),
            hypothetical_fen: AnalysisResult(bestmove="g1f3", evaluation=-60, mate_in=None),
        }
    )

    response = asyncio.run(
        handle_analyze_hypothetical(
            args={"player_move": "pawn to e5"},
            game_store=store,
            stockfish_engine=engine,
        )
    )

    assert response["eval_delta"] == 110
    assert response["opponent_best_reply_san"] == "Nf3"


def test_handle_analyze_hypothetical_returns_parse_error_for_unparseable_text() -> None:
    store = GameStateStore()
    engine = FakeStockfishEngine({})

    response = asyncio.run(
        handle_analyze_hypothetical(
            args={"player_move": "do the thing"},
            game_store=store,
            stockfish_engine=engine,
        )
    )

    assert response["parse_error"] is True


def test_handle_analyze_hypothetical_returns_illegal_move_for_illegal_candidate(monkeypatch) -> None:
    store = GameStateStore()
    engine = FakeStockfishEngine({})
    monkeypatch.setattr("services.socratic_coach.parse_natural_move", lambda natural_move, fen: "e1e4")

    response = asyncio.run(
        handle_analyze_hypothetical(
            args={"player_move": "something illegal"},
            game_store=store,
            stockfish_engine=engine,
        )
    )

    assert response["illegal_move"] is True
