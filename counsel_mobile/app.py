"""Single-owner cloud API. Exposes no upstream admin or key-management endpoints."""
import asyncio
import hashlib
import hmac
import json
import os
import secrets
import sqlite3
import time
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import FastAPI, Depends, HTTPException, Request, Response
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from .engine import deliberate, install_providers

DATA = Path(os.environ.get("MOBILE_DATA_DIR", "data/mobile"))
TOKEN = os.environ.get("MOBILE_ACCESS_TOKEN", "")
tasks = set()


def db():
    DATA.mkdir(parents=True, exist_ok=True)
    conn = sqlite3.connect(DATA / "council.sqlite", timeout=10)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    return conn


def init_db():
    with db() as c:
        c.executescript("""
        CREATE TABLE IF NOT EXISTS memory(id TEXT PRIMARY KEY, text TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS jobs(id TEXT PRIMARY KEY, question TEXT NOT NULL,
          status TEXT NOT NULL, payload TEXT NOT NULL, created REAL NOT NULL);
        UPDATE jobs SET status='interrupted' WHERE status='running';
        """)


@asynccontextmanager
async def lifespan(app):
    if len(TOKEN) < 32:
        raise RuntimeError("MOBILE_ACCESS_TOKEN 必须配置至少 32 个字符")
    init_db()
    install_providers()
    yield
    for task in tasks:
        task.cancel()
    if tasks:
        await asyncio.gather(*tasks, return_exceptions=True)


app = FastAPI(title="人格议事厅", lifespan=lifespan, docs_url=None, redoc_url=None, openapi_url=None)


def signature(stamp):
    return hmac.new(TOKEN.encode(), stamp.encode(), hashlib.sha256).hexdigest()


def authenticated(request: Request):
    auth = request.headers.get("authorization", "")
    if TOKEN and secrets.compare_digest(auth, "Bearer " + TOKEN):
        return
    cookie = request.cookies.get("council_session", "")
    try:
        stamp, sig = cookie.split(".", 1)
        age = time.time() - int(stamp)
        if TOKEN and 0 <= age < 86400 and secrets.compare_digest(sig, signature(stamp)):
            return
    except (ValueError, TypeError):
        pass
    raise HTTPException(401, "请先登录")


@app.middleware("http")
async def browser_security(request: Request, call_next):
    # JSON bodies plus same-origin validation protect cookie-based mutations.
    if request.method in ("POST", "PUT", "DELETE"):
        origin = request.headers.get("origin")
        expected = os.environ.get("MOBILE_PUBLIC_ORIGIN", "").rstrip("/") or str(request.base_url).rstrip("/")
        if origin and origin != expected:
            return Response(status_code=403)
    result = await call_next(request)
    result.headers["X-Content-Type-Options"] = "nosniff"
    result.headers["Cache-Control"] = "no-store"
    result.headers["Content-Security-Policy"] = "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    return result


@app.get("/")
def index():
    return FileResponse(Path(__file__).with_name("index.html"))


@app.get("/health")
def health():
    return {"status": "ok"}


class Login(BaseModel):
    token: str = Field(max_length=300)


attempts = {}


@app.post("/api/mobile/login")
async def login(body: Login, request: Request, response: Response):
    # One owner: a global rate limit avoids untrusted forwarded-IP headers.
    now = time.monotonic()
    recent = [t for t in attempts.get("login", []) if now - t < 60]
    if len(recent) >= 10:
        raise HTTPException(429, "稍后再试")
    attempts["login"] = recent + [now]
    if len(TOKEN) < 32 or not secrets.compare_digest(body.token, TOKEN):
        raise HTTPException(401, "访问口令错误")
    stamp = str(int(time.time()))
    response.set_cookie("council_session", stamp + "." + signature(stamp), max_age=86400, httponly=True,
                        secure=os.environ.get("MOBILE_DEV_HTTP") != "1", samesite="strict")
    return {"ok": True}


class Question(BaseModel):
    question: str = Field(min_length=1, max_length=6000)


class Memory(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


@app.get("/api/mobile/memory", dependencies=[Depends(authenticated)])
def memories():
    with db() as c:
        return [dict(x) for x in c.execute("SELECT * FROM memory ORDER BY rowid")]


@app.post("/api/mobile/memory", dependencies=[Depends(authenticated)])
def remember(body: Memory):
    if not body.text.strip():
        raise HTTPException(422, "记忆不能为空")
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        if c.execute("SELECT COUNT(*) FROM memory").fetchone()[0] >= 20:
            raise HTTPException(409, "最多保存 20 条记忆，请先清理")
        mid = secrets.token_hex(16)
        c.execute("INSERT INTO memory VALUES (?,?)", (mid, body.text.strip()))
    return {"id": mid}


@app.delete("/api/mobile/memory/{mid}", dependencies=[Depends(authenticated)])
def forget(mid: str):
    with db() as c:
        c.execute("DELETE FROM memory WHERE id=?", (mid,))
    return {"ok": True}


@app.get("/api/mobile/jobs", dependencies=[Depends(authenticated)])
def jobs():
    with db() as c:
        return [dict(x) for x in c.execute("SELECT id,question,status,created FROM jobs ORDER BY created DESC LIMIT 50")]


@app.get("/api/mobile/jobs/{jid}", dependencies=[Depends(authenticated)])
def job(jid: str):
    with db() as c:
        row = c.execute("SELECT * FROM jobs WHERE id=?", (jid,)).fetchone()
    if not row:
        raise HTTPException(404, "记录不存在")
    return {**dict(row), "payload": json.loads(row["payload"])}


@app.delete("/api/mobile/jobs/{jid}", dependencies=[Depends(authenticated)])
def delete_job(jid: str):
    with db() as c:
        row = c.execute("SELECT status FROM jobs WHERE id=?", (jid,)).fetchone()
        if row and row["status"] == "running":
            raise HTTPException(409, "讨论中不能删除")
        c.execute("DELETE FROM jobs WHERE id=?", (jid,))
    return {"ok": True}


@app.post("/api/mobile/ask", dependencies=[Depends(authenticated)])
async def ask(body: Question):
    if not body.question.strip():
        raise HTTPException(422, "问题不能为空")
    jid = secrets.token_hex(16)
    with db() as c:
        c.execute("BEGIN IMMEDIATE")
        if c.execute("SELECT COUNT(*) FROM jobs WHERE status='running'").fetchone()[0]:
            raise HTTPException(409, "已有讨论进行中，请打开历史记录查看")
        c.execute("INSERT INTO jobs VALUES (?,?,?,?,?)", (jid, body.question.strip(), "running", '{}', time.time()))
        memory = [x[0] for x in c.execute("SELECT text FROM memory ORDER BY rowid")]
        history = []
        for row in c.execute("SELECT question,payload FROM jobs WHERE status='done' ORDER BY created DESC LIMIT 4"):
            history.append({"question": row[0], "answer": json.loads(row[1]).get("final", {}).get("content", "")[:2500]})
        history.reverse()

    async def run():
        payload = {}
        async def progress(stage, **parts):
            payload.update(parts)
            payload["stage"] = stage
            with db() as c:
                c.execute("UPDATE jobs SET payload=? WHERE id=?", (json.dumps(payload, ensure_ascii=False), jid))
        try:
            answer = await deliberate(body.question.strip(), memory, history, progress)
            payload.update(answer)
            status = "done"
        except ValueError as exc:
            payload["error"] = str(exc)
            status = "failed"
        except Exception:
            payload["error"] = "服务异常，请检查服务端日志或模型配置"
            status = "failed"
        with db() as c:
            c.execute("UPDATE jobs SET status=?,payload=? WHERE id=?", (status, json.dumps(payload, ensure_ascii=False), jid))
    task = asyncio.create_task(run())
    tasks.add(task)
    task.add_done_callback(tasks.discard)
    return {"id": jid}
