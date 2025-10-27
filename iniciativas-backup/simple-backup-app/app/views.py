"""Vistas y rutas de FastAPI."""
from __future__ import annotations

from datetime import datetime

from fastapi import APIRouter, Depends, Form, HTTPException, Request
from fastapi.responses import HTMLResponse, RedirectResponse
from fastapi.templating import Jinja2Templates

from .dependencies import get_app_config, get_messages, get_restore_service
from .models import RestoreRequest


templates = Jinja2Templates(directory="templates")
router = APIRouter()


@router.get("/", response_class=HTMLResponse)
def index(
    request: Request,
    config=Depends(get_app_config),
    messages: list[str] = Depends(get_messages),
):
    return templates.TemplateResponse(
        "index.html",
        {
            "request": request,
            "accounts": config.accounts,
            "messages": list(messages),
            "now": datetime.utcnow(),
        },
    )


@router.get("/accounts/{account_id}", response_class=HTMLResponse)
def account_detail(
    request: Request,
    account_id: str,
    restore_service=Depends(get_restore_service),
    messages: list[str] = Depends(get_messages),
):
    try:
        account = restore_service.get_account(account_id)
    except KeyError as exc:
        raise HTTPException(status_code=404, detail=str(exc)) from exc

    backups = list(restore_service.list_backup_objects(account_id))
    return templates.TemplateResponse(
        "account_detail.html",
        {
            "request": request,
            "account": account,
            "backups": backups,
            "messages": list(messages),
            "now": datetime.utcnow(),
        },
    )


@router.post("/accounts/{account_id}/restore")
def restore_backup(
    request: Request,
    account_id: str,
    object_key: str = Form(...),
    strategy: str = Form("copy"),
    destination_bucket: str = Form(""),
    destination_prefix: str = Form(""),
    restore_service=Depends(get_restore_service),
):
    try:
        restore_request = RestoreRequest(
            account_id=account_id,
            object_key=object_key,
            strategy=strategy,
            destination_bucket=destination_bucket or None,
            destination_prefix=destination_prefix,
        )
        result = restore_service.restore(restore_request)
    except Exception as exc:  # pragma: no cover - UI muestra error
        request.session.setdefault("messages", []).append(
            f"⚠️ Error al restaurar {object_key}: {exc}"
        )
    else:
        request.session.setdefault("messages", []).append(
            f"✅ {result.message}: {result.destination}"
        )

    response = RedirectResponse(
        request.url_for("account_detail", account_id=account_id), status_code=303
    )
    return response


