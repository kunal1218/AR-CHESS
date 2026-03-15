import sys
import uuid
from datetime import datetime, timezone
from pathlib import Path
from types import SimpleNamespace

import httpx
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient


SERVER_APP_ROOT = Path(__file__).resolve().parents[1]
if str(SERVER_APP_ROOT) not in sys.path:
    sys.path.insert(0, str(SERVER_APP_ROOT))

from main import (  # noqa: E402
    app,
    build_passive_narrator_line_query,
    build_narrator_prompt,
    build_narrator_turn_addon,
    build_piece_voice_line_duplicate_retry_query,
    build_piece_voice_line_query,
    build_piece_voice_line_retry_query,
    get_postgres_dsn,
    is_placeholder_value,
    narrator_personality_addon,
    normalize_piece_voice_line_text,
    normalize_postgres_dsn,
    parse_gemini_coach_response,
    sanitize_hint_text,
    sanitize_lesson_feedback_text,
    sanitize_passive_narrator_line_text,
    sanitize_piece_voice_line_text,
)


def test_fastapi_app_bootstraps() -> None:
    assert app.title == "AR Chess Server"


def test_health_ping_reports_server_and_postgres(monkeypatch) -> None:
    monkeypatch.setattr("main.ping_postgres", lambda: (True, "Postgres ping successful"))

    client = TestClient(app)
    response = client.get("/health/ping")

    assert response.status_code == 200
    assert response.json()["messages"] == [
        "Server ping successful",
        "Postgres ping successful",
    ]


def test_create_game_returns_generated_game_id(monkeypatch) -> None:
    game_id = uuid.UUID("11111111-1111-1111-1111-111111111111")
    monkeypatch.setattr("main.create_game_record", lambda: game_id)

    client = TestClient(app)
    response = client.post("/v1/games")

    assert response.status_code == 200
    assert response.json() == {"game_id": str(game_id)}


def test_record_game_move_persists_uci_move(monkeypatch) -> None:
    game_id = uuid.UUID("22222222-2222-2222-2222-222222222222")
    created_at = datetime(2026, 2, 28, 12, 0, tzinfo=timezone.utc)

    def fake_save_game_move(game_id: uuid.UUID, ply: int, move_uci: str) -> dict[str, object]:
        return {
            "game_id": game_id,
            "ply": ply,
            "move_uci": move_uci,
            "created_at": created_at,
        }

    monkeypatch.setattr("main.save_game_move", fake_save_game_move)

    client = TestClient(app)
    response = client.post(
        f"/v1/games/{game_id}/moves",
        json={"ply": 1, "move_uci": "E2E4"},
    )

    assert response.status_code == 200
    assert response.json()["game_id"] == str(game_id)
    assert response.json()["ply"] == 1
    assert response.json()["move_uci"] == "e2e4"


def test_record_game_move_rejects_non_uci_notation() -> None:
    game_id = uuid.UUID("33333333-3333-3333-3333-333333333333")
    client = TestClient(app)
    response = client.post(
        f"/v1/games/{game_id}/moves",
        json={"ply": 1, "move_uci": "Nf3+"},
    )

    assert response.status_code == 422
    assert "UCI notation" in response.text


def test_get_game_moves_returns_ordered_log(monkeypatch) -> None:
    game_id = uuid.UUID("44444444-4444-4444-4444-444444444444")
    created_at = datetime(2026, 2, 28, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.fetch_game_moves",
        lambda game_id: [
            {
                "game_id": game_id,
                "ply": 1,
                "move_uci": "e2e4",
                "created_at": created_at,
            },
            {
                "game_id": game_id,
                "ply": 2,
                "move_uci": "e7e5",
                "created_at": created_at,
            },
        ],
    )

    client = TestClient(app)
    response = client.get(f"/v1/games/{game_id}/moves")

    assert response.status_code == 200
    assert response.json()["game_id"] == str(game_id)
    assert [item["move_uci"] for item in response.json()["moves"]] == ["e2e4", "e7e5"]


def test_enqueue_matchmaking_returns_ticket(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.enqueue_player_for_matchmaking",
        lambda player_id: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "queued",
            "match_id": None,
            "assigned_color": None,
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.post("/v1/matchmaking/enqueue", json={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["ticket_id"] == str(ticket_id)
    assert response.json()["status"] == "queued"


def test_heartbeat_matchmaking_refreshes_ticket(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    match_id = uuid.UUID("cccccccc-cccc-cccc-cccc-cccccccccccc")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.heartbeat_matchmaking_ticket",
        lambda ticket_id, player_id: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "matched",
            "match_id": match_id,
            "assigned_color": "white",
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.post(
        f"/v1/matchmaking/{ticket_id}/heartbeat",
        json={"player_id": str(player_id)},
    )

    assert response.status_code == 200
    assert response.json()["status"] == "matched"
    assert response.json()["assigned_color"] == "white"


def test_get_matchmaking_ticket_returns_status(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.get_matchmaking_ticket",
        lambda ticket_id, player_id=None: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "queued",
            "match_id": None,
            "assigned_color": None,
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.get(f"/v1/matchmaking/{ticket_id}", params={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["player_id"] == str(player_id)


def test_cancel_matchmaking_ticket_returns_cancelled(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    ticket_id = uuid.UUID("bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb")
    expires_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    heartbeat_at = datetime(2026, 3, 1, 11, 59, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.cancel_matchmaking_ticket",
        lambda ticket_id, player_id: {
            "ticket_id": ticket_id,
            "player_id": player_id,
            "status": "cancelled",
            "match_id": None,
            "assigned_color": None,
            "heartbeat_at": heartbeat_at,
            "expires_at": expires_at,
            "poll_after_ms": 1000,
        },
    )

    client = TestClient(app)
    response = client.delete(f"/v1/matchmaking/{ticket_id}", params={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["status"] == "cancelled"


def test_get_match_state_returns_current_server_state(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    match_id = uuid.UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    game_id = uuid.UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
    created_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.get_match_state_record",
        lambda match_id, player_id=None: {
            "match_id": match_id,
            "game_id": game_id,
            "status": "active",
            "white_player_id": player_id,
            "black_player_id": uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff"),
            "your_color": "white",
            "latest_ply": 2,
            "next_turn": "white",
            "moves": [
                {
                    "match_id": match_id,
                    "game_id": game_id,
                    "ply": 1,
                    "move_uci": "e2e4",
                    "player_id": player_id,
                    "created_at": created_at,
                }
            ],
        },
    )

    client = TestClient(app)
    response = client.get(f"/v1/matches/{match_id}/state", params={"player_id": str(player_id)})

    assert response.status_code == 200
    assert response.json()["your_color"] == "white"
    assert response.json()["next_turn"] == "white"


def test_post_match_move_returns_conflict_with_current_state(monkeypatch) -> None:
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    match_id = uuid.UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    current_state = {
        "match_id": str(match_id),
        "game_id": "eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee",
        "status": "active",
        "your_color": "white",
        "latest_ply": 2,
        "next_turn": "white",
        "moves": [],
    }

    def fake_record_queue_match_move(
        match_id: uuid.UUID,
        player_id: uuid.UUID,
        ply: int,
        move_uci: str,
    ) -> dict[str, object]:
        raise HTTPException(
            status_code=409,
            detail={
                "message": "Expected ply 3, received 2.",
                "current_state": current_state,
            },
        )

    monkeypatch.setattr("main.record_queue_match_move", fake_record_queue_match_move)

    client = TestClient(app)
    response = client.post(
        f"/v1/matches/{match_id}/moves",
        json={"player_id": str(player_id), "ply": 2, "move_uci": "d2d4"},
    )

    assert response.status_code == 409
    assert response.json()["detail"]["current_state"]["latest_ply"] == 2


def test_get_match_moves_supports_after_ply(monkeypatch) -> None:
    match_id = uuid.UUID("dddddddd-dddd-dddd-dddd-dddddddddddd")
    game_id = uuid.UUID("eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee")
    player_id = uuid.UUID("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa")
    created_at = datetime(2026, 3, 1, 12, 0, tzinfo=timezone.utc)
    monkeypatch.setattr(
        "main.get_queue_match_moves",
        lambda match_id, after_ply, player_id=None: {
            "match_id": match_id,
            "game_id": game_id,
            "latest_ply": 4,
            "next_turn": "white",
            "moves": [
                {
                    "match_id": match_id,
                    "game_id": game_id,
                    "ply": 3,
                    "move_uci": "g1f3",
                    "player_id": player_id,
                    "created_at": created_at,
                },
                {
                    "match_id": match_id,
                    "game_id": game_id,
                    "ply": 4,
                    "move_uci": "b8c6",
                    "player_id": uuid.UUID("ffffffff-ffff-ffff-ffff-ffffffffffff"),
                    "created_at": created_at,
                },
            ],
        },
    )

    client = TestClient(app)
    response = client.get(
        f"/v1/matches/{match_id}/moves",
        params={"after_ply": 2, "player_id": str(player_id)},
    )

    assert response.status_code == 200
    assert [item["ply"] for item in response.json()["moves"]] == [3, 4]


def test_get_gemini_status_returns_live_state(monkeypatch) -> None:
    monkeypatch.setattr("main.GEMINI_LIVE_CLIENT.ensure_connection_background", lambda: None)
    monkeypatch.setattr(
        "main.GEMINI_LIVE_CLIENT.get_status",
        lambda: {
            "state": "CONNECTED",
            "lastError": None,
            "since": "2026-03-01T12:00:00+00:00",
        },
    )

    client = TestClient(app)
    response = client.get("/v1/gemini/status")

    assert response.status_code == 200
    assert response.json()["state"] == "CONNECTED"
    assert response.json()["lastError"] is None
    assert response.json()["since"].startswith("2026-03-01T12:00:00")


def test_gemini_live_socket_passes_narrator_query_param(monkeypatch) -> None:
    observed: dict[str, object] = {}

    class FakeSession:
        def __init__(self, **kwargs):
            observed["narrator"] = kwargs.get("narrator")
            self._frontend_socket = kwargs["frontend_socket"]

        async def run(self) -> None:
            await self._frontend_socket.accept()
            await self._frontend_socket.send_json({"type": "status", "state": "ready"})

        async def close(self) -> None:
            observed["closed"] = True

    monkeypatch.setattr("main.SocraticCoachSession", FakeSession)

    client = TestClient(app)
    with client.websocket_connect("/v1/gemini/live?narrator=fletcher") as websocket:
        payload = websocket.receive_json()

    assert payload == {"type": "status", "state": "ready"}
    assert observed["narrator"] == "fletcher"
    assert observed["closed"] is True


def test_create_gemini_hint_returns_sanitized_hint(monkeypatch) -> None:
    async def fake_run_turn(prompt: str, *, metadata=None, timeout_seconds: float = 0.0) -> str:
        assert "Provide one short beginner-friendly hint" in prompt
        assert build_narrator_turn_addon("fletcher") in prompt
        assert metadata["current_fen"].startswith("rnbqkbnr")
        assert metadata["recent_history"] == "13. Re1 b5 14. Bb3 Nf6 15. O-O"
        assert metadata["best_move"] == "e2e4"
        _ = timeout_seconds
        return "Play e2e4 and own the center!"

    monkeypatch.setattr("main.GEMINI_LIVE_CLIENT.run_turn", fake_run_turn)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/hint",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
            "recent_history": "13. Re1 b5 14. Bb3 Nf6 15. O-O",
            "best_move": "e2e4",
            "side_to_move": "white",
            "narrator": "fletcher",
            "moving_piece": "pawn",
            "is_capture": False,
            "gives_check": False,
            "themes": ["fight for the center"],
        },
    )

    assert response.status_code == 200
    # Coordinates are stripped via fallback to keep hints beginner-friendly.
    assert response.json()["hint"] == "Good. Grab central space instead of drifting around doing nothing."


def test_sanitize_hint_text_caps_to_one_sentence() -> None:
    fallback = "Fallback hint."
    raw_text = "Hit the center hard. Then pile onto the weak king. Do not drift."

    assert sanitize_hint_text(raw_text, fallback) == "Hit the center hard."


def test_sanitize_lesson_feedback_text_caps_to_two_sentences() -> None:
    fallback = "Fallback lesson feedback."
    raw_text = (
        "That move neglects development. Your king stays exposed. "
        "You also gave up the center for no reason."
    )

    assert sanitize_lesson_feedback_text(raw_text, fallback) == (
        "That move neglects development. Your king stays exposed."
    )


def test_sanitize_piece_voice_line_text_caps_word_count_and_strips_labels() -> None:
    raw_text = 'Knight: "A graceful leap toward glory and danger with far too many extra words for one short line indeed."'

    sanitized = sanitize_piece_voice_line_text(raw_text)

    assert not sanitized.startswith("Knight:")
    assert '"' not in sanitized
    assert len(sanitized.split()) <= 20


def test_normalize_piece_voice_line_text_does_not_add_terminal_punctuation() -> None:
    assert normalize_piece_voice_line_text("I crush their line and keep") == "I crush their line and keep"


def test_build_gemini_lesson_feedback_query_includes_narrator_addon() -> None:
    from main import GeminiLessonFeedbackRequest, build_gemini_lesson_feedback_query

    payload = GeminiLessonFeedbackRequest(
        fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBNR w KQkq - 0 1",
        lesson_title="Italian Opening",
        attempted_move="a2a3",
        correct_move="g1f3",
        side_to_move="white",
        narrator="fletcher",
        focus="Develop pieces toward the center.",
    )

    query = build_gemini_lesson_feedback_query(payload)

    assert build_narrator_turn_addon("fletcher") in query


def test_build_piece_voice_line_query_includes_personality_and_context() -> None:
    from main import GeminiPieceVoiceRequest

    payload = GeminiPieceVoiceRequest(
        fen="rnbqkbnr/pppppppp/8/8/4N3/8/PPPPPPPP/RNBQKB1R b KQkq - 1 1",
        piece_type="knight",
        piece_color="white",
        recent_lines=["A stylish leap was overdue."],
        from_square="g1",
        to_square="e4",
        is_capture=False,
        is_check=False,
        is_near_enemy_king=False,
        is_attacked=True,
        is_attacked_by_multiple=False,
        is_defended=True,
        is_well_defended=False,
        is_hanging=False,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=True,
        attacker_count=1,
        defender_count=1,
        eval_before=20,
        eval_after=95,
        eval_delta=75,
        position_state="equal",
        move_quality="tactical",
    )

    query = build_piece_voice_line_query(payload)

    assert "Output exactly one short in-character line." in query
    assert "Focused piece personality: Knight: fancy, chivalrous" in query
    assert "Move: g1 to e4" in query
    assert "Fork threat: yes" in query
    assert "Move quality: tactical" in query
    assert "Minimum 3 words." in query
    assert "Return exactly one complete sentence" in query
    assert "single word, single letter" in query
    assert "Recent lines to avoid repeating:" in query
    assert "A stylish leap was overdue." in query

    retry_query = build_piece_voice_line_retry_query(payload, 'Knight: "Too long."')
    assert "3 to 12 words" in retry_query
    assert "complete sentence ending with punctuation" in retry_query
    assert "Do not reuse the previous wording." in retry_query
    assert 'Previous invalid answer: Knight: "Too long."' in retry_query

    duplicate_retry_query = build_piece_voice_line_duplicate_retry_query(
        payload,
        "A stylish leap was overdue.",
    )
    assert "repeated recent wording" in duplicate_retry_query
    assert "noticeably different phrasing" in duplicate_retry_query

    from main import build_piece_voice_line_repair_query

    repair_query = build_piece_voice_line_repair_query(payload, "By holy")
    assert "incomplete fragment" in repair_query
    assert "finished in-character sentence" in repair_query


def test_build_piece_voice_line_query_supports_ambient_piece_context() -> None:
    from main import GeminiPieceVoiceRequest

    payload = GeminiPieceVoiceRequest(
        fen="rnbqkbnr/pppppppp/8/8/4N3/8/PPPPPPPP/RNBQKB1R b KQkq - 1 1",
        piece_type="queen",
        piece_color="black",
        context_mode="ambient",
        from_square="d8",
        to_square="d8",
        is_capture=False,
        is_check=False,
        is_near_enemy_king=False,
        is_attacked=False,
        is_attacked_by_multiple=False,
        is_defended=True,
        is_well_defended=True,
        is_hanging=False,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=False,
        is_fork_threat=False,
        attacker_count=0,
        defender_count=2,
        eval_before=0,
        eval_after=-80,
        eval_delta=-80,
        position_state="losing",
        move_quality="defensive",
    )

    query = build_piece_voice_line_query(payload)

    assert "Context mode: ambient" in query
    assert "did not just move" in query
    assert "Current square: d8" in query


def test_build_piece_voice_line_query_uses_piece_only_dialogue_history() -> None:
    from main import GeminiPieceVoiceRequest, PieceDialoguePromptControls, build_piece_voice_line_query

    payload = GeminiPieceVoiceRequest(
        fen="r1bqkbnr/pppp1ppp/2n5/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R w KQkq - 2 3",
        piece_type="knight",
        piece_color="white",
        recent_lines=["I smell a weak square."],
        dialogue_mode="history_reactive",
        piece_dialogue_history=[
            {
                "speaker_class": "piece",
                "piece_type": "pawn",
                "piece_color": "white",
                "piece_identity": "White Pawn on e4",
                "text": "Forward. The center wants blood.",
            }
        ],
        latest_piece_line={
            "speaker_class": "piece",
            "piece_type": "pawn",
            "piece_color": "white",
            "piece_identity": "White Pawn on e4",
            "text": "Forward. The center wants blood.",
        },
        context_mode="moved",
        from_square="f3",
        to_square="e5",
        is_capture=False,
        is_check=False,
        is_near_enemy_king=False,
        is_attacked=True,
        is_attacked_by_multiple=False,
        is_defended=True,
        is_well_defended=False,
        is_hanging=False,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=True,
        attacker_count=1,
        defender_count=1,
        eval_before=24,
        eval_after=80,
        eval_delta=56,
        position_state="equal",
        move_quality="tactical",
    )

    query = build_piece_voice_line_query(
        payload,
        prompt_controls=PieceDialoguePromptControls(
            dialogue_intent="mock",
            line_style="taunting",
            focus_target="enemy",
            emotional_flavor="smug",
            avoid_direct_address=False,
            conversation_loop_detected=False,
        ),
    )

    assert "Dialogue mode: history_reactive" in query
    assert "Speak in first person from inside the battle." in query
    assert "Pieces can hear other pieces, but never the narrator." in query
    assert "Recent piece-only battlefield chatter you may react to:" in query
    assert "White Pawn on e4" in query
    assert "Most recent piece line in the air:" in query
    assert "React to recent battlefield chatter if appropriate" in query
    assert "Dialogue intent: mock" in query
    assert "Line style: taunting" in query
    assert "Focus target: enemy" in query
    assert "Emotional flavor: smug" in query
    assert "Avoid direct address: no" in query
    assert "Conversation loop detected: no" in query


def test_build_piece_voice_line_query_supports_underutilized_snark_mode() -> None:
    from main import GeminiPieceVoiceRequest, PieceDialoguePromptControls, build_piece_voice_line_query

    payload = GeminiPieceVoiceRequest(
        fen="r1bqkbnr/pppp1ppp/2n5/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R w KQkq - 2 3",
        piece_type="rook",
        piece_color="white",
        recent_lines=["I move once. The whole file shudders."],
        dialogue_mode="underutilized_snark",
        context_mode="ambient",
        from_square="a1",
        to_square="a1",
        is_capture=False,
        is_check=False,
        is_near_enemy_king=False,
        is_attacked=False,
        is_attacked_by_multiple=False,
        is_defended=True,
        is_well_defended=True,
        is_hanging=False,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=False,
        is_fork_threat=False,
        attacker_count=0,
        defender_count=2,
        eval_before=12,
        eval_after=18,
        eval_delta=6,
        position_state="equal",
        move_quality="routine",
        piece_move_count=0,
        underutilized_reason="stuck on the back rank with no open file",
    )

    query = build_piece_voice_line_query(
        payload,
        prompt_controls=PieceDialoguePromptControls(
            dialogue_intent="dismiss",
            line_style="clipped",
            focus_target="self",
            emotional_flavor="smug",
            avoid_direct_address=False,
            conversation_loop_detected=False,
        ),
    )

    assert "Dialogue mode: underutilized_snark" in query
    assert "least-used pieces and you are finally speaking up" in query
    assert "Do not sound like a coach" in query
    assert "Piece move count so far: 0" in query
    assert "Complaint cue: stuck on the back rank with no open file" in query
    assert "You are not commenting on the move you just made." in query


def test_build_piece_dialogue_prompt_controls_detects_ping_pong_loop() -> None:
    from main import GeminiPieceVoiceRequest, build_piece_dialogue_prompt_controls

    payload = GeminiPieceVoiceRequest(
        fen="r1bqkbnr/pppp1ppp/2n5/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R w KQkq - 2 3",
        piece_type="bishop",
        piece_color="white",
        dialogue_mode="history_reactive",
        piece_dialogue_history=[
            {
                "speaker_class": "piece",
                "piece_type": "pawn",
                "piece_color": "white",
                "piece_identity": "White Pawn on e4",
                "text": "Ok knight, keep up.",
            },
            {
                "speaker_class": "piece",
                "piece_type": "knight",
                "piece_color": "black",
                "piece_identity": "Black Knight on c6",
                "text": "Listen pawn, you are late.",
            },
            {
                "speaker_class": "piece",
                "piece_type": "pawn",
                "piece_color": "white",
                "piece_identity": "White Pawn on e4",
                "text": "Ok knight, march faster.",
            },
            {
                "speaker_class": "piece",
                "piece_type": "knight",
                "piece_color": "black",
                "piece_identity": "Black Knight on c6",
                "text": "Listen pawn, do not lecture me.",
            },
        ],
        latest_piece_line={
            "speaker_class": "piece",
            "piece_type": "knight",
            "piece_color": "black",
            "piece_identity": "Black Knight on c6",
            "text": "Listen pawn, do not lecture me.",
        },
        context_mode="moved",
        from_square="c1",
        to_square="g5",
        is_capture=False,
        is_check=False,
        is_near_enemy_king=False,
        is_attacked=False,
        is_attacked_by_multiple=False,
        is_defended=True,
        is_well_defended=False,
        is_hanging=False,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=False,
        attacker_count=0,
        defender_count=1,
        eval_before=12,
        eval_after=35,
        eval_delta=23,
        position_state="equal",
        move_quality="strong",
    )

    controls = build_piece_dialogue_prompt_controls(payload)

    assert controls.dialogue_intent in {
        "threaten",
        "mock",
        "boast",
        "warn",
        "panic",
        "celebrate",
        "command",
        "dismiss",
    }
    assert controls.line_style in {
        "clipped",
        "dramatic",
        "cold",
        "taunting",
        "grim",
        "battlefield_command",
    }
    assert controls.focus_target in {"self", "enemy", "battle", "king", "survival"}
    assert controls.emotional_flavor in {"confident", "vicious", "smug", "desperate", "solemn", "unstable"}
    assert controls.avoid_direct_address is True
    assert controls.conversation_loop_detected is True


def test_build_piece_voice_line_query_can_suppress_direct_address_loops() -> None:
    from main import GeminiPieceVoiceRequest, PieceDialoguePromptControls, build_piece_voice_line_query

    payload = GeminiPieceVoiceRequest(
        fen="r1bqkbnr/pppp1ppp/2n5/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R w KQkq - 2 3",
        piece_type="bishop",
        piece_color="white",
        dialogue_mode="history_reactive",
        piece_dialogue_history=[
            {
                "speaker_class": "piece",
                "piece_type": "pawn",
                "piece_color": "white",
                "piece_identity": "White Pawn on e4",
                "text": "Ok knight, keep up.",
            }
        ],
        latest_piece_line={
            "speaker_class": "piece",
            "piece_type": "pawn",
            "piece_color": "white",
            "piece_identity": "White Pawn on e4",
            "text": "Ok knight, keep up.",
        },
        context_mode="moved",
        from_square="c1",
        to_square="g5",
        is_capture=False,
        is_check=False,
        is_near_enemy_king=False,
        is_attacked=False,
        is_attacked_by_multiple=False,
        is_defended=True,
        is_well_defended=False,
        is_hanging=False,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=False,
        attacker_count=0,
        defender_count=1,
        eval_before=12,
        eval_after=35,
        eval_delta=23,
        position_state="equal",
        move_quality="strong",
    )

    query = build_piece_voice_line_query(
        payload,
        prompt_controls=PieceDialoguePromptControls(
            dialogue_intent="dismiss",
            line_style="grim",
            focus_target="battle",
            emotional_flavor="solemn",
            avoid_direct_address=True,
            conversation_loop_detected=True,
        ),
    )

    assert "Avoid directly addressing another piece by name or type." in query
    assert "Recent chatter is looping" in query
    assert "Dialogue intent: dismiss" in query
    assert "Line style: grim" in query
    assert "Focus target: battle" in query
    assert "Emotional flavor: solemn" in query
    assert "Avoid direct address: yes" in query
    assert "Conversation loop detected: yes" in query


def test_build_passive_narrator_line_query_includes_story_context() -> None:
    from main import GeminiPassiveNarratorRequest

    payload = GeminiPassiveNarratorRequest(
        fen="rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 2",
        recent_history="1. e4 e5 2. d4",
        recent_lines=["The board stays calm on the surface, but the pressure keeps building."],
        phase="move",
        turns_since_last_narrator_line=3,
        move_san="...exd4",
        moving_piece="pawn",
        moving_color="black",
        from_square="e5",
        to_square="d4",
        is_capture=True,
        is_check=False,
        is_checkmate=False,
        is_near_enemy_king=False,
        is_attacked=True,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=False,
        attacker_count=1,
        defender_count=0,
        eval_before=18,
        eval_after=-42,
        eval_delta=-60,
        position_state="equal",
        move_quality="tactical",
    )

    query = build_passive_narrator_line_query(payload)

    assert "story-like commentary" in query
    assert "same level of chess understanding as a strong coach" in query
    assert "Every line must contain at least one concrete chess idea" in query
    assert "Never address the player as you or your." in query
    assert "Turns since last narrator line: 3" in query
    assert "Moving piece: black pawn" in query
    assert "Capture: yes" in query
    assert "Recent narrator lines to avoid repeating:" in query


def test_build_passive_narrator_line_query_can_react_to_latest_piece_line() -> None:
    from main import GeminiPassiveNarratorRequest, build_passive_narrator_line_query

    payload = GeminiPassiveNarratorRequest(
        fen="rnbqkbnr/pppp1ppp/8/4p3/3PP3/5N2/PPP2PPP/RNBQKB1R b KQkq - 1 2",
        phase="move",
        dialogue_mode="piece_reactive",
        latest_piece_line={
            "speaker_class": "piece",
            "piece_type": "knight",
            "piece_color": "white",
            "piece_identity": "White Knight on f3",
            "text": "A finer road opens from here.",
        },
        turns_since_last_narrator_line=2,
        move_san="...exd4",
        moving_piece="pawn",
        moving_color="black",
        from_square="e5",
        to_square="d4",
        is_capture=True,
        is_check=False,
        is_checkmate=False,
        is_near_enemy_king=False,
        is_attacked=True,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=False,
        attacker_count=1,
        defender_count=0,
        eval_before=18,
        eval_after=-42,
        eval_delta=-60,
        position_state="equal",
        move_quality="tactical",
    )

    query = build_passive_narrator_line_query(payload)

    assert "Dialogue mode: piece_reactive" in query
    assert "Most recent piece line you may react to:" in query
    assert "White Knight on f3" in query
    assert "Pieces cannot hear the narrator" in query
    assert "React to it like a cinematic observer, not a participant." in query


def test_is_passive_narrator_line_too_vague_rejects_generic_or_instructive_lines() -> None:
    from main import GeminiPassiveNarratorRequest, is_passive_narrator_line_too_vague

    payload = GeminiPassiveNarratorRequest(
        fen="rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 2",
        phase="move",
        turns_since_last_narrator_line=3,
        move_san="...exd4",
        moving_piece="pawn",
        moving_color="black",
        from_square="e5",
        to_square="d4",
        is_capture=True,
        is_check=False,
        is_checkmate=False,
        is_near_enemy_king=False,
        is_attacked=True,
        is_pinned=False,
        is_retreat=False,
        is_aggressive_advance=True,
        is_fork_threat=False,
        attacker_count=1,
        defender_count=0,
        eval_before=18,
        eval_after=-42,
        eval_delta=-60,
        position_state="equal",
        move_quality="tactical",
    )

    assert is_passive_narrator_line_too_vague("The board is a mess, but your pieces scream loud.", payload) is True
    assert is_passive_narrator_line_too_vague("White must consolidate the center now.", payload) is True
    assert is_passive_narrator_line_too_vague(
        "That capture leaves the center thinner and the defenders less coordinated.",
        payload,
    ) is False


def test_piece_voice_request_rejects_non_piece_dialogue_history() -> None:
    from pydantic import ValidationError
    from main import GeminiPieceVoiceRequest

    with pytest.raises(ValidationError):
        GeminiPieceVoiceRequest(
            fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            piece_type="rook",
            piece_color="white",
            dialogue_mode="history_reactive",
            piece_dialogue_history=[
                {
                    "speaker_class": "narrator",
                    "text": "A hush settles over the board.",
                }
            ],
            context_mode="moved",
            from_square="h1",
            to_square="g1",
            is_capture=False,
            is_check=False,
            is_near_enemy_king=False,
            is_attacked=False,
            is_attacked_by_multiple=False,
            is_defended=True,
            is_well_defended=True,
            is_hanging=False,
            is_pinned=False,
            is_retreat=False,
            is_aggressive_advance=False,
            is_fork_threat=False,
            attacker_count=0,
            defender_count=2,
            eval_before=40,
            eval_after=120,
            eval_delta=80,
            position_state="winning",
            move_quality="strong",
        )


def test_piece_voice_request_rejects_non_piece_latest_piece_line() -> None:
    from pydantic import ValidationError
    from main import GeminiPieceVoiceRequest

    with pytest.raises(ValidationError):
        GeminiPieceVoiceRequest(
            fen="rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            piece_type="rook",
            piece_color="white",
            dialogue_mode="history_reactive",
            latest_piece_line={
                "speaker_class": "narrator",
                "text": "A hush settles over the board.",
            },
            context_mode="moved",
            from_square="h1",
            to_square="g1",
            is_capture=False,
            is_check=False,
            is_near_enemy_king=False,
            is_attacked=False,
            is_attacked_by_multiple=False,
            is_defended=True,
            is_well_defended=True,
            is_hanging=False,
            is_pinned=False,
            is_retreat=False,
            is_aggressive_advance=False,
            is_fork_threat=False,
            attacker_count=0,
            defender_count=2,
            eval_before=40,
            eval_after=120,
            eval_delta=80,
            position_state="winning",
            move_quality="strong",
        )


def test_sanitize_passive_narrator_line_text_strips_labels_and_blocks_coordinates() -> None:
    fallback = "The board stays calm on the surface, but the pressure keeps building."

    sanitized = sanitize_passive_narrator_line_text(
        'Narrator: "A tense hush settles over the board. Something is about to give."',
        fallback,
    )
    assert sanitized == "A tense hush settles over the board. Something is about to give."

    assert sanitize_passive_narrator_line_text("Knight lands on e4.", fallback) == fallback


def test_build_narrator_prompt_appends_selected_personality() -> None:
    silky_prompt = build_narrator_prompt("silky")
    fletcher_prompt = build_narrator_prompt("fletcher")

    assert "Your core responsibility never changes" in silky_prompt
    assert narrator_personality_addon("silky") in silky_prompt
    assert narrator_personality_addon("fletcher") in fletcher_prompt
    assert "Do not just roleplay anger. Teach through the anger." in fletcher_prompt


def test_parse_gemini_coach_response_extracts_json_object() -> None:
    response = parse_gemini_coach_response(
        """
        {
          "side_to_move": "white",
          "top_3_workers": [
            {"piece": "White Knight", "square": "d5", "reason": "Controls the center."}
          ],
          "top_3_traitors": [
            {"piece": "White Rook", "square": "a1", "reason": "Still sleeping."}
          ],
          "coach_lines": [
            "Your knight on d5 is your hardest worker right now."
          ]
        }
        """
    )

    assert response.side_to_move == "white"
    assert response.top_3_workers[0].square == "d5"
    assert response.coach_lines == ["Your knight on d5 is your hardest worker right now."]


def test_create_gemini_commentary_returns_structured_json(monkeypatch) -> None:
    async def fake_fetch(payload):
        assert payload.fen.startswith("rnbqkbnr")
        assert payload.narrator == "fletcher"
        return parse_gemini_coach_response(
            """
            {
              "side_to_move": "white",
              "top_3_workers": [
                {
                  "piece": "White Knight",
                  "square": "f3",
                  "reason": "Controls e5 and g5."
                },
                {
                  "piece": "White Bishop",
                  "square": "c4",
                  "reason": "Leans on f7."
                },
                {
                  "piece": "White Pawn",
                  "square": "e4",
                  "reason": "Claims central space."
                }
              ],
              "top_3_traitors": [
                {
                  "piece": "White Rook",
                  "square": "h1",
                  "reason": "Still boxed in."
                },
                {
                  "piece": "White Pawn",
                  "square": "a2",
                  "reason": "Not influencing the main fight."
                },
                {
                  "piece": "White Pawn",
                  "square": "h2",
                  "reason": "Also quiet for now."
                }
              ],
              "coach_lines": [
                "Your knight on f3 is your hardest worker right now."
              ]
            }
            """
        )

    monkeypatch.setattr("main.fetch_gemini_coach_commentary", fake_fetch)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/commentary",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/5N2/PPPPPPPP/RNBQKB1R w KQkq - 0 1",
            "narrator": "fletcher",
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "side_to_move": "white",
        "top_3_workers": [
            {
                "piece": "White Knight",
                "square": "f3",
                "reason": "Controls e5 and g5.",
            },
            {
                "piece": "White Bishop",
                "square": "c4",
                "reason": "Leans on f7.",
            },
            {
                "piece": "White Pawn",
                "square": "e4",
                "reason": "Claims central space.",
            },
        ],
        "top_3_traitors": [
            {
                "piece": "White Rook",
                "square": "h1",
                "reason": "Still boxed in.",
            },
            {
                "piece": "White Pawn",
                "square": "a2",
                "reason": "Not influencing the main fight.",
            },
            {
                "piece": "White Pawn",
                "square": "h2",
                "reason": "Also quiet for now.",
            },
        ],
        "coach_lines": [
            "Your knight on f3 is your hardest worker right now."
        ],
    }


def test_create_gemini_piece_voice_line_returns_sanitized_line(monkeypatch) -> None:
    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        assert "generateContent" in url
        assert "single short in-character voice line" in json["contents"][0]["parts"][0]["text"]
        assert "Focused piece personality: Rook: brutish, ogre-like, blunt." in json["contents"][0]["parts"][0]["text"]
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {"text": '"Rook: Break them now."'}
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "rook",
            "piece_color": "white",
            "from_square": "h1",
            "to_square": "g1",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": True,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": False,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 2,
            "eval_before": 40,
            "eval_after": 120,
            "eval_delta": 80,
            "position_state": "winning",
            "move_quality": "strong",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "Break them now."}


def test_create_piper_tts_audio_returns_cached_metadata(monkeypatch) -> None:
    monkeypatch.setattr(
        "main.PIPER_TTS_SERVICE.synthesize",
        lambda speaker_type, text: SimpleNamespace(
            requested_speaker_type=speaker_type,
            resolved_speaker_type="rook",
            cache_key="rook-rook-break-them-now-1234567890abcdef1234567890abcdef",
            cache_hit=True,
            used_fallback_voice=False,
            audio_path=Path("/tmp/rook.wav"),
        ),
    )

    client = TestClient(app)
    response = client.post(
        "/v1/tts/piper/speak",
        json={
            "speaker_type": "rook",
            "text": "Break them now.",
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "speaker_type": "rook",
        "resolved_speaker_type": "rook",
        "cache_key": "rook-rook-break-them-now-1234567890abcdef1234567890abcdef",
        "cache_hit": True,
        "used_fallback_voice": False,
        "audio_url": "http://testserver/v1/tts/piper/audio/rook-rook-break-them-now-1234567890abcdef1234567890abcdef",
    }


def test_list_piper_tts_voices_returns_installed_voice_inventory(monkeypatch) -> None:
    monkeypatch.setattr(
        "main.PIPER_TTS_SERVICE.list_available_voices",
        lambda: SimpleNamespace(
            default_speaker_type="narrator",
            speaker_assignments={
                "pawn": None,
                "rook": "rook/en_US-lessac-medium",
                "knight": "knight/en_US-lessac-medium",
                "bishop": None,
                "queen": None,
                "king": None,
                "narrator": "narrator/en_US-lessac-medium",
            },
            voices=[
                SimpleNamespace(
                    voice_id="knight/en_US-lessac-medium",
                    name="en_US-lessac-medium",
                    language="en-us",
                    quality="medium",
                    sample_rate=22050,
                    configured_speaker_types=("knight",),
                ),
                SimpleNamespace(
                    voice_id="rook/en_US-lessac-medium",
                    name="en_US-lessac-medium",
                    language="en-us",
                    quality="medium",
                    sample_rate=22050,
                    configured_speaker_types=("rook",),
                ),
            ],
        ),
    )

    client = TestClient(app)
    response = client.get("/v1/tts/piper/voices")

    assert response.status_code == 200
    assert response.json() == {
        "default_speaker_type": "narrator",
        "speaker_assignments": {
            "pawn": None,
            "rook": "rook/en_US-lessac-medium",
            "knight": "knight/en_US-lessac-medium",
            "bishop": None,
            "queen": None,
            "king": None,
            "narrator": "narrator/en_US-lessac-medium",
        },
        "voices": [
            {
                "voice_id": "knight/en_US-lessac-medium",
                "name": "en_US-lessac-medium",
                "language": "en-us",
                "quality": "medium",
                "sample_rate": 22050,
                "configured_speaker_types": ["knight"],
            },
            {
                "voice_id": "rook/en_US-lessac-medium",
                "name": "en_US-lessac-medium",
                "language": "en-us",
                "quality": "medium",
                "sample_rate": 22050,
                "configured_speaker_types": ["rook"],
            },
        ],
    }


def test_create_piper_tts_audition_returns_cached_metadata(monkeypatch) -> None:
    monkeypatch.setattr(
        "main.PIPER_TTS_SERVICE.synthesize_audition",
        lambda voice_id, text: SimpleNamespace(
            voice_id=voice_id,
            cache_key="audition-knight-a-fast-test-line-1234567890abcdef1234567890abcdef",
            cache_hit=False,
            audio_path=Path("/tmp/knight-audition.wav"),
        ),
    )

    client = TestClient(app)
    response = client.post(
        "/v1/tts/piper/audition",
        json={
            "voice_id": "knight/en_US-lessac-medium",
            "text": "A fast test line.",
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "voice_id": "knight/en_US-lessac-medium",
        "cache_key": "audition-knight-a-fast-test-line-1234567890abcdef1234567890abcdef",
        "cache_hit": False,
        "audio_url": "http://testserver/v1/tts/piper/audio/audition-knight-a-fast-test-line-1234567890abcdef1234567890abcdef",
    }


def test_assign_piper_tts_voice_returns_updated_assignment(monkeypatch) -> None:
    monkeypatch.setattr(
        "main.PIPER_TTS_SERVICE.assign_voice",
        lambda speaker_type, voice_id: SimpleNamespace(
            speaker_assignments={
                "pawn": None,
                "rook": None,
                "knight": voice_id,
                "bishop": None,
                "queen": None,
                "king": None,
                "narrator": None,
            }
        ),
    )

    client = TestClient(app)
    response = client.put(
        "/v1/tts/piper/voices/assignments/knight",
        json={"voice_id": "knight/en_US-lessac-high"},
    )

    assert response.status_code == 200
    assert response.json() == {
        "speaker_type": "knight",
        "assigned_voice_id": "knight/en_US-lessac-high",
    }


def test_get_piper_tts_audio_returns_cached_wav(monkeypatch, tmp_path: Path) -> None:
    audio_path = tmp_path / "rook.wav"
    audio_path.write_bytes(b"RIFFfakewavdata")
    monkeypatch.setattr("main.PIPER_TTS_SERVICE.audio_path_for_cache_key", lambda cache_key: audio_path)

    client = TestClient(app)
    response = client.get("/v1/tts/piper/audio/rook-rook-break-them-now-1234567890abcdef1234567890abcdef")

    assert response.status_code == 200
    assert response.headers["content-type"] == "audio/wav"
    assert response.content == b"RIFFfakewavdata"


def test_create_gemini_passive_commentary_line_returns_sanitized_line(monkeypatch) -> None:
    prompts: list[str] = []

    async def fake_run_turn(query: str, *, metadata=None, timeout_seconds=0) -> str:
        prompts.append(query)
        assert metadata["current_fen"].startswith("rnbqkbnr")
        assert metadata["phase"] == "move"
        assert timeout_seconds > 0
        return 'Narrator: "A tense hush settles over the board. Something important is leaning."'

    monkeypatch.setattr("main.GEMINI_PASSIVE_COMMENTARY_CLIENT.run_turn", fake_run_turn)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/passive-commentary-line",
        json={
            "fen": "rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 2",
            "recent_history": "1. e4 e5 2. d4",
            "recent_lines": ["The board stays calm on the surface, but the pressure keeps building."],
            "phase": "move",
            "turns_since_last_narrator_line": 3,
            "move_san": "...exd4",
            "moving_piece": "pawn",
            "moving_color": "black",
            "from_square": "e5",
            "to_square": "d4",
            "is_capture": True,
            "is_check": False,
            "is_checkmate": False,
            "is_near_enemy_king": False,
            "is_attacked": True,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 1,
            "defender_count": 0,
            "eval_before": 18,
            "eval_after": -42,
            "eval_delta": -60,
            "position_state": "equal",
            "move_quality": "tactical",
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "line": "A tense hush settles over the board. Something important is leaning."
    }
    assert len(prompts) == 1
    assert "story-like commentary" in prompts[0]


def test_create_gemini_passive_commentary_line_retries_recent_duplicate(monkeypatch) -> None:
    responses = iter(
        [
            "The board stays calm on the surface, but the pressure keeps building.",
            "The position still looks quiet, but the strain is starting to show.",
        ]
    )
    prompts: list[str] = []

    async def fake_run_turn(query: str, *, metadata=None, timeout_seconds=0) -> str:
        prompts.append(query)
        _ = metadata
        _ = timeout_seconds
        return next(responses)

    monkeypatch.setattr("main.GEMINI_PASSIVE_COMMENTARY_CLIENT.run_turn", fake_run_turn)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/passive-commentary-line",
        json={
            "fen": "rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 2",
            "phase": "move",
            "turns_since_last_narrator_line": 4,
            "move_san": "...exd4",
            "moving_piece": "pawn",
            "moving_color": "black",
            "from_square": "e5",
            "to_square": "d4",
            "is_capture": False,
            "is_check": False,
            "is_checkmate": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 0,
            "eval_before": 18,
            "eval_after": -42,
            "eval_delta": -60,
            "position_state": "equal",
            "move_quality": "routine",
            "recent_lines": ["The board stays calm on the surface, but the pressure keeps building."],
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "line": "The position still looks quiet, but the strain is starting to show."
    }
    assert len(prompts) == 2
    assert "Previous answer to replace" in prompts[1]


def test_create_gemini_passive_commentary_line_retries_vague_narration(monkeypatch) -> None:
    responses = iter(
        [
            "The board is a mess, but your pieces scream loud.",
            "The center is cracking open, and the defenders are late to seal it.",
        ]
    )
    prompts: list[str] = []

    async def fake_run_turn(query: str, *, metadata=None, timeout_seconds=0) -> str:
        prompts.append(query)
        _ = metadata
        _ = timeout_seconds
        return next(responses)

    monkeypatch.setattr("main.GEMINI_PASSIVE_COMMENTARY_CLIENT.run_turn", fake_run_turn)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/passive-commentary-line",
        json={
            "fen": "rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 2",
            "phase": "move",
            "turns_since_last_narrator_line": 4,
            "move_san": "...exd4",
            "moving_piece": "pawn",
            "moving_color": "black",
            "from_square": "e5",
            "to_square": "d4",
            "is_capture": True,
            "is_check": False,
            "is_checkmate": False,
            "is_near_enemy_king": False,
            "is_attacked": True,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 1,
            "defender_count": 0,
            "eval_before": 18,
            "eval_after": -42,
            "eval_delta": -60,
            "position_state": "equal",
            "move_quality": "tactical",
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "line": "The center is cracking open, and the defenders are late to seal it."
    }
    assert len(prompts) == 2
    assert "drifted into coaching, or stayed too vague" in prompts[1]


def test_create_gemini_passive_commentary_line_falls_back_when_model_uses_coordinates(monkeypatch) -> None:
    async def fake_run_turn(query: str, *, metadata=None, timeout_seconds=0) -> str:
        _ = query
        _ = metadata
        _ = timeout_seconds
        return "The knight lands on e4."

    monkeypatch.setattr("main.GEMINI_PASSIVE_COMMENTARY_CLIENT.run_turn", fake_run_turn)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/passive-commentary-line",
        json={
            "fen": "rnbqkbnr/pppp1ppp/8/4p3/3PP3/8/PPP2PPP/RNBQKBNR b KQkq - 0 2",
            "phase": "opening",
            "turns_since_last_narrator_line": 0,
        },
    )

    assert response.status_code == 200
    assert response.json() == {
        "line": "The board is set, and both plans are still hiding their teeth."
    }


def test_create_gemini_piece_voice_line_retries_empty_response(monkeypatch) -> None:
    responses = iter(["   ", "A sanctified strike through the dark."])
    prompts: list[str] = []

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        current = next(responses)
        prompts.append(json["contents"][0]["parts"][0]["text"])
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {"text": current}
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "bishop",
            "piece_color": "white",
            "from_square": "f1",
            "to_square": "c4",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": True,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 2,
            "eval_before": -40,
            "eval_after": -10,
            "eval_delta": 30,
            "position_state": "losing",
            "move_quality": "aggressive",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "A sanctified strike through the dark."}
    assert len(prompts) == 2
    assert "Do not reuse the previous wording." in prompts[1]


def test_create_gemini_piece_voice_line_reranks_multiple_candidates_for_novelty(monkeypatch) -> None:
    from main import reset_piece_voice_global_memory

    reset_piece_voice_global_memory()
    prompts: list[str] = []
    candidate_counts: list[int] = []

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        prompts.append(json["contents"][0]["parts"][0]["text"])
        candidate_counts.append(json["generationConfig"]["candidateCount"])
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {"content": {"parts": [{"text": "Forward. The trench still wants bodies."}]}, "finishReason": "STOP"},
                    {"content": {"parts": [{"text": "Boots forward. The killing field is hungry."}]}, "finishReason": "STOP"},
                    {"content": {"parts": [{"text": "Listen knight, the mud outranks you."}]}, "finishReason": "STOP"},
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "pawn",
            "piece_color": "white",
            "recent_lines": ["Forward. The trench still wants bodies."],
            "from_square": "e2",
            "to_square": "e4",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": False,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 1,
            "eval_before": 10,
            "eval_after": 24,
            "eval_delta": 14,
            "position_state": "equal",
            "move_quality": "aggressive",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "Boots forward. The killing field is hungry."}
    assert candidate_counts == [3]
    assert len(prompts) == 1
    reset_piece_voice_global_memory()


def test_create_gemini_piece_voice_line_penalizes_globally_overused_lines(monkeypatch) -> None:
    from main import record_piece_voice_global_usage, reset_piece_voice_global_memory

    reset_piece_voice_global_memory()
    for _ in range(4):
        record_piece_voice_global_usage("Forward. The trench still wants bodies.")

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {"content": {"parts": [{"text": "Forward. The trench still wants bodies."}]}, "finishReason": "STOP"},
                    {"content": {"parts": [{"text": "Another square taken. The trench opens wider."}]}, "finishReason": "STOP"},
                    {"content": {"parts": [{"text": "Forward again. Mud first, glory second."}]}, "finishReason": "STOP"},
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "pawn",
            "piece_color": "white",
            "from_square": "e2",
            "to_square": "e4",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": False,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 1,
            "eval_before": 10,
            "eval_after": 24,
            "eval_delta": 14,
            "position_state": "equal",
            "move_quality": "aggressive",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "Another square taken. The trench opens wider."}
    reset_piece_voice_global_memory()


def test_create_gemini_piece_voice_line_retries_recent_duplicate(monkeypatch) -> None:
    responses = iter(
        [
            "Forward. The trench still wants bodies.",
            "Boots forward. The killing field is hungry.",
        ]
    )
    prompts: list[str] = []

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        current = next(responses)
        prompts.append(json["contents"][0]["parts"][0]["text"])
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {"text": current}
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "pawn",
            "piece_color": "white",
            "recent_lines": ["Forward. The trench still wants bodies."],
            "from_square": "e2",
            "to_square": "e4",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": False,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": True,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 1,
            "eval_before": 10,
            "eval_after": 24,
            "eval_delta": 14,
            "position_state": "equal",
            "move_quality": "aggressive",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "Boots forward. The killing field is hungry."}
    assert len(prompts) == 2
    assert "Recent lines to avoid repeating:" in prompts[0]
    assert "repeated recent wording" in prompts[1]


def test_create_gemini_piece_voice_line_retries_truncated_sentence_without_punctuation(monkeypatch) -> None:
    responses = iter(["I crush their line and keep", "I crush their line and keep marching."])
    prompts: list[str] = []

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        current = next(responses)
        prompts.append(json["contents"][0]["parts"][0]["text"])
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {"text": current}
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "rook",
            "piece_color": "white",
            "from_square": "h1",
            "to_square": "g1",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": True,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": False,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 2,
            "eval_before": 40,
            "eval_after": 120,
            "eval_delta": 80,
            "position_state": "winning",
            "move_quality": "strong",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "I crush their line and keep marching."}
    assert len(prompts) == 2
    assert "Do not reuse the previous wording." in prompts[1]


def test_create_gemini_piece_voice_line_retries_max_tokens_finish_reason(monkeypatch) -> None:
    responses = iter(
        [
            {
                "candidates": [
                    {
                        "finishReason": "MAX_TOKENS",
                        "content": {
                            "parts": [
                                {"text": "I crush their line and keep"}
                            ]
                        },
                    }
                ]
            },
            {
                "candidates": [
                    {
                        "finishReason": "STOP",
                        "content": {
                            "parts": [
                                {"text": "I crush their line and keep marching."}
                            ]
                        },
                    }
                ]
            },
        ]
    )
    prompts: list[str] = []

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        current = next(responses)
        prompts.append(json["contents"][0]["parts"][0]["text"])
        _ = headers
        return httpx.Response(
            200,
            json=current,
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "rook",
            "piece_color": "white",
            "from_square": "h1",
            "to_square": "g1",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": True,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": False,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 2,
            "eval_before": 40,
            "eval_after": 120,
            "eval_delta": 80,
            "position_state": "winning",
            "move_quality": "strong",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "I crush their line and keep marching."}
    assert len(prompts) == 2
    assert "Do not reuse the previous wording." in prompts[1]


def test_create_gemini_piece_voice_line_repairs_fragment_response(monkeypatch) -> None:
    responses = iter(["By holy", "Judgment", "Judgment falls now."])
    prompts: list[str] = []

    async def fake_post(self, url: str, *, headers=None, json=None) -> httpx.Response:
        current = next(responses)
        prompts.append(json["contents"][0]["parts"][0]["text"])
        _ = headers
        return httpx.Response(
            200,
            json={
                "candidates": [
                    {
                        "content": {
                            "parts": [
                                {"text": current}
                            ]
                        }
                    }
                ]
            },
            request=httpx.Request("POST", url),
        )

    monkeypatch.setattr(httpx.AsyncClient, "post", fake_post)

    client = TestClient(app)
    response = client.post(
        "/v1/gemini/piece-voice-line",
        json={
            "fen": "rnbqkbnr/pppppppp/8/8/8/8/PPPPPPPP/RNBQKBR1 w KQkq - 0 1",
            "piece_type": "rook",
            "piece_color": "white",
            "from_square": "h1",
            "to_square": "g1",
            "is_capture": False,
            "is_check": False,
            "is_near_enemy_king": False,
            "is_attacked": False,
            "is_attacked_by_multiple": False,
            "is_defended": True,
            "is_well_defended": True,
            "is_hanging": False,
            "is_pinned": False,
            "is_retreat": False,
            "is_aggressive_advance": False,
            "is_fork_threat": False,
            "attacker_count": 0,
            "defender_count": 2,
            "eval_before": 10,
            "eval_after": 55,
            "eval_delta": 45,
            "position_state": "equal",
            "move_quality": "strong",
        },
    )

    assert response.status_code == 200
    assert response.json() == {"line": "Judgment falls now."}
    assert len(prompts) == 3
    assert "Do not reuse the previous wording." in prompts[1]
    assert "finished in-character sentence" in prompts[2]


def test_get_postgres_dsn_prefers_railway_private_url(monkeypatch) -> None:
    monkeypatch.setenv("DATABASE_PRIVATE_URL", "postgres://user:pass@private-host:5432/railway")
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:pass@public-host:5432/railway")

    assert get_postgres_dsn() == "postgresql://user:pass@private-host:5432/railway"


def test_get_postgres_dsn_supports_pg_fallback_vars(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_PRIVATE_URL", raising=False)
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("DATABASE_PUBLIC_URL", raising=False)
    monkeypatch.setenv("PGHOST", "railway.internal")
    monkeypatch.setenv("PGPORT", "5432")
    monkeypatch.setenv("PGDATABASE", "railway")
    monkeypatch.setenv("PGUSER", "postgres")
    monkeypatch.setenv("PGPASSWORD", "secret")

    assert get_postgres_dsn() == "postgresql://postgres:secret@railway.internal:5432/railway"


def test_normalize_postgres_dsn_rewrites_postgres_scheme() -> None:
    assert normalize_postgres_dsn("postgres://user:pass@host:5432/db") == (
        "postgresql://user:pass@host:5432/db"
    )


def test_get_postgres_dsn_skips_placeholder_database_url(monkeypatch) -> None:
    monkeypatch.delenv("DATABASE_PRIVATE_URL", raising=False)
    monkeypatch.delenv("DATABASE_PUBLIC_URL", raising=False)
    monkeypatch.setenv(
        "DATABASE_URL",
        "postgresql://postgres:password@your-railway-postgres-host:5432/railway",
    )
    monkeypatch.setenv("PGHOST", "railway.internal")
    monkeypatch.setenv("PGPORT", "5432")
    monkeypatch.setenv("PGDATABASE", "railway")
    monkeypatch.setenv("PGUSER", "postgres")
    monkeypatch.setenv("PGPASSWORD", "secret")

    assert get_postgres_dsn() == "postgresql://postgres:secret@railway.internal:5432/railway"


def test_is_placeholder_value_detects_template_markers() -> None:
    assert is_placeholder_value("postgresql://x:y@your-railway-postgres-host:5432/railway")
    assert is_placeholder_value("https://your-railway-service.up.railway.app")
