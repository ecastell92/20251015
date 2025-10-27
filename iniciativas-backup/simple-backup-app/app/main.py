"""Punto de entrada FastAPI."""
from __future__ import annotations

from pathlib import Path

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles
from starlette.middleware.sessions import SessionMiddleware

from .views import router


BASE_DIR = Path(__file__).resolve().parent.parent

app = FastAPI(title="Simple Backup Restore")
app.add_middleware(SessionMiddleware, secret_key="change-me")
app.mount("/static", StaticFiles(directory=BASE_DIR / "static"), name="static")
app.include_router(router)


@app.get("/health")
def health_check() -> dict[str, str]:
    return {"status": "ok"}


