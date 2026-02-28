import os

from fastapi import FastAPI
from fastapi.responses import JSONResponse
from dotenv import load_dotenv
import psycopg
import uvicorn

load_dotenv()

DEFAULT_POSTGRES_PORT = 5432


app = FastAPI(
    title="AR Chess Server",
    description="Empty FastAPI scaffold for the AR Chess backend.",
    version="0.1.0",
)


def get_postgres_dsn() -> str:
    database_url = os.getenv("DATABASE_URL", "").strip()
    if database_url:
        return database_url

    host = os.getenv("POSTGRES_HOST", "localhost")
    port = os.getenv("POSTGRES_PORT", str(DEFAULT_POSTGRES_PORT))
    database = os.getenv("POSTGRES_DB", "archess")
    user = os.getenv("POSTGRES_USER", "archess")
    password = os.getenv("POSTGRES_PASSWORD", "archess")

    return f"postgresql://{user}:{password}@{host}:{port}/{database}"


def ping_postgres() -> tuple[bool, str]:
    try:
        with psycopg.connect(get_postgres_dsn(), connect_timeout=3) as connection:
            with connection.cursor() as cursor:
                cursor.execute("SELECT 1")
                cursor.fetchone()

        return True, "Postgres ping successful"
    except Exception as exc:
        return False, f"Postgres ping failed: {exc}"


@app.get("/health/ping")
def health_ping() -> JSONResponse:
    postgres_ok, postgres_message = ping_postgres()
    payload = {
        "ok": postgres_ok,
        "messages": [
            "Server ping successful",
            postgres_message,
        ],
        "checks": {
            "server": {
                "ok": True,
                "message": "Server ping successful",
            },
            "postgres": {
                "ok": postgres_ok,
                "message": postgres_message,
            },
        },
    }

    return JSONResponse(status_code=200 if postgres_ok else 503, content=payload)


if __name__ == "__main__":
    port = int(os.getenv("PORT", "8000"))
    uvicorn.run("main:app", host="0.0.0.0", port=port, reload=True)
