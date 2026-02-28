from main import app


def test_fastapi_app_bootstraps() -> None:
    assert app.title == "AR Chess Server"
