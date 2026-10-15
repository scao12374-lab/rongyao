import asyncio
import importlib
import json
import pytest
from fastapi.testclient import TestClient
from counsel_mobile.engine import deliberate


@pytest.fixture
def client(tmp_path, monkeypatch):
    monkeypatch.setenv("MOBILE_DATA_DIR", str(tmp_path))
    monkeypatch.setenv("MOBILE_ACCESS_TOKEN", "a" * 40)
    module = importlib.import_module("counsel_mobile.app")
    monkeypatch.setattr(module, "DATA", tmp_path)
    monkeypatch.setattr(module, "TOKEN", "a" * 40)
    monkeypatch.setattr(module, "install_providers", lambda: None)
    module.attempts.clear()
    with TestClient(module.app, base_url="https://testserver") as c:
        yield c, module


def test_auth_csrf_memory_and_deletion(client):
    c, module = client
    assert c.get("/api/mobile/jobs").status_code == 401
    assert c.post("/api/mobile/login", json={"token": "wrong"}).status_code == 401
    assert c.post("/api/mobile/login", json={"token": "a" * 40}).status_code == 200
    assert "HttpOnly" in c.cookies.jar._cookies["testserver.local"]["/"]["council_session"]._rest
    assert c.post("/api/mobile/memory", headers={"Origin": "https://evil.example"}, json={"text": "bad"}).status_code == 403
    mid = c.post("/api/mobile/memory", json={"text": "偏好低成本"}).json()["id"]
    assert c.get("/api/mobile/memory").json()[0]["text"] == "偏好低成本"
    c.delete("/api/mobile/memory/" + mid)
    assert c.get("/api/mobile/memory").json() == []
    assert c.post("/api/mobile/ask", json={"question": "   "}).status_code == 422


def test_background_failure_and_recovery(client, monkeypatch):
    c, module = client
    c.headers["Authorization"] = "Bearer " + "a" * 40
    async def fail(*args):
        raise ValueError("模型不可用")
    monkeypatch.setattr(module, "deliberate", fail)
    jid = c.post("/api/mobile/ask", json={"question": "测试"}).json()["id"]
    # Flush the event loop; the job continues independently of the request.
    c.get("/health")
    row = c.get("/api/mobile/jobs/" + jid).json()
    assert row["status"] == "failed"
    assert row["payload"]["error"] == "模型不可用"
    with module.db() as db:
        db.execute("UPDATE jobs SET status='running' WHERE id=?", (jid,))
    assert c.post("/api/mobile/ask", json={"question": "重复"}).status_code == 409
    module.init_db()
    assert c.get("/api/mobile/jobs/" + jid).json()["status"] == "interrupted"
    assert c.delete("/api/mobile/jobs/" + jid).status_code == 200
    assert c.get("/api/mobile/jobs/" + jid).status_code == 404


@pytest.mark.asyncio
async def test_blind_review_partial_failure_and_fixed_chair(monkeypatch):
    for key, value in {"CHAIRMAN_MODEL": "openai:chair", "DEEPSEEK_MODEL": "deepseek:one", "DOUBAO_MODEL": "doubao:two", "QWEN_MODEL": "qwen:three"}.items():
        monkeypatch.setenv(key, value)
    calls = []
    async def query(model, messages):
        calls.append((model, messages))
        if model == "qwen:three":
            return {"error": True, "error_message": "secret-value"}
        return {"content": "回答来自 " + model}
    async def progress(*args, **kwargs):
        pass
    result = await deliberate("如何选择", ["偏好可执行"], [], progress, query)
    assert result["final"]["model"] == "openai:chair"
    assert result["degraded"]
    assert "secret-value" not in json.dumps(result)
    # Model identities are absent as metadata; peers may self-identify in content.
    review = calls[3:5]
    assert len(review) == 2
    for model, messages in review:
        prompt = messages[-1]["content"]
        assert "回答来自 " + model not in prompt
        assert '"编号"' in prompt


@pytest.mark.asyncio
async def test_all_models_fail_no_false_final(monkeypatch):
    monkeypatch.setenv("CHAIRMAN_MODEL", "openai:chair")
    monkeypatch.setenv("DEEPSEEK_MODEL", "deepseek:one")
    monkeypatch.delenv("DOUBAO_MODEL", raising=False)
    monkeypatch.delenv("QWEN_MODEL", raising=False)
    async def query(*args):
        return {"error": True}
    async def progress(*args, **kwargs):
        pass
    with pytest.raises(ValueError, match="所有副模型"):
        await deliberate("问题", [], [], progress, query)
