"""デーモンの生死確認。"""

from __future__ import annotations

import os

from fastapi import APIRouter, Depends, Request

from device_bridge.daemon.auth import verify_token
from device_bridge.daemon.safety import get_safety

router = APIRouter(tags=["health"], dependencies=[Depends(verify_token)])


@router.get("/health")
def health(request: Request) -> dict[str, object]:
    """デーモンが応答できることと、いま何人が SSE を購読しているかを返す。

    macOS アプリはこれをポーリングして接続状態を出す。
    """
    return {
        "status": "ok",
        "pid": os.getpid(),
        "subscribers": request.app.state.events.subscriber_count,
        # どの機能が OFF になっているか、デバッグで一目で分かるように出す。
        # キーの形は Swift 側と共有する契約(camelCase)のまま。
        "safety": get_safety(request).to_payload(),
    }
