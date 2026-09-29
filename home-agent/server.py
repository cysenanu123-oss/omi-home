#!/usr/bin/env python3
"""
Ama — Personal AI Home Assistant
Network-accessible voice + vision assistant running on your local machine.
Access from any device: http://<your-pc-ip>:3000
"""

import asyncio, json, os, socket, urllib.parse
from pathlib import Path
from typing import Optional

import httpx, psutil
from bs4 import BeautifulSoup
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from google import genai
from google.genai import types

# ─── Config ────────────────────────────────────────────────────────────────────
GEMINI_API_KEY = os.getenv("GEMINI_API_KEY", "")
ASSISTANT_NAME = "Ama"
HOST = "0.0.0.0"
PORT = 3000

client: Optional[genai.Client] = None
if GEMINI_API_KEY:
    client = genai.Client(api_key=GEMINI_API_KEY)
else:
    print("⚠️  GEMINI_API_KEY not set. Get a free key at https://aistudio.google.com/")

MODEL = "gemini-1.5-flash"

# ─── System Prompt ─────────────────────────────────────────────────────────────
SYSTEM_PROMPT = f"""You are {ASSISTANT_NAME}, a powerful personal AI home assistant running on the user's local Linux machine. You have full admin access.

You can run shell commands, open apps and URLs, read/write files, search the web, and get system info.

Personality: Confident, warm, efficient. Speak in 1-3 sentences unless detail is needed. Say what you're doing before you do it.

Safety rules:
- HIGH RISK (rm -rf, format, dd, sudo modifying system): Call research_safety first, then the UI will ask the user for confirmation.
- MEDIUM RISK (kill process, install software): The UI will ask confirmation automatically.
- LOW RISK (open app, search, read file, system info): Execute immediately.

Respond naturally as if you're in the room with the user."""

# ─── Tool Schemas ───────────────────────────────────────────────────────────────
TOOLS = [types.Tool(function_declarations=[
    types.FunctionDeclaration(
        name="run_shell",
        description="Execute a shell command. Set risk_level honestly: low/medium/high.",
        parameters=types.Schema(type="OBJECT", properties={
            "command":    types.Schema(type="STRING", description="Shell command to execute"),
            "risk_level": types.Schema(type="STRING", enum=["low","medium","high"],
                                       description="Danger level of this command"),
        }, required=["command","risk_level"]),
    ),
    types.FunctionDeclaration(
        name="open_app",
        description="Open an application by name or open a URL in the browser.",
        parameters=types.Schema(type="OBJECT", properties={
            "target": types.Schema(type="STRING", description="App name or URL"),
        }, required=["target"]),
    ),
    types.FunctionDeclaration(
        name="search_web",
        description="Search DuckDuckGo and return the top results.",
        parameters=types.Schema(type="OBJECT", properties={
            "query": types.Schema(type="STRING"),
        }, required=["query"]),
    ),
    types.FunctionDeclaration(
        name="system_info",
        description="Get current system information.",
        parameters=types.Schema(type="OBJECT", properties={
            "type": types.Schema(type="STRING", enum=["cpu","ram","disk","processes","all"]),
        }, required=["type"]),
    ),
    types.FunctionDeclaration(
        name="read_file",
        description="Read a file from the filesystem.",
        parameters=types.Schema(type="OBJECT", properties={
            "path": types.Schema(type="STRING"),
        }, required=["path"]),
    ),
    types.FunctionDeclaration(
        name="write_file",
        description="Write content to a file.",
        parameters=types.Schema(type="OBJECT", properties={
            "path":    types.Schema(type="STRING"),
            "content": types.Schema(type="STRING"),
        }, required=["path","content"]),
    ),
    types.FunctionDeclaration(
        name="research_safety",
        description="Search online to understand risks of a dangerous operation. Always call before high-risk commands.",
        parameters=types.Schema(type="OBJECT", properties={
            "operation": types.Schema(type="STRING"),
        }, required=["operation"]),
    ),
])]

# ─── Tool Implementations ───────────────────────────────────────────────────────
async def _run_shell(command: str) -> str:
    try:
        proc = await asyncio.create_subprocess_shell(
            command,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.STDOUT,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
        out = stdout.decode("utf-8", errors="replace").strip()
        return out[:3000] or "(no output)"
    except asyncio.TimeoutError:
        return "Command timed out after 30 seconds."
    except Exception as e:
        return f"Error: {e}"

async def _open_app(target: str) -> str:
    cmd = f"xdg-open '{target}'" if target.startswith("http") else \
          f"xdg-open '{target}' 2>/dev/null || nohup {target} &>/dev/null &"
    await asyncio.create_subprocess_shell(cmd)
    return f"Opened {target}."

async def _search_web(query: str) -> str:
    try:
        url = f"https://html.duckduckgo.com/html/?q={urllib.parse.quote(query)}"
        headers = {"User-Agent": "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"}
        async with httpx.AsyncClient(timeout=10, follow_redirects=True) as c:
            resp = await c.get(url, headers=headers)
        soup = BeautifulSoup(resp.text, "html.parser")
        results = []
        for r in soup.select(".result")[:5]:
            t = r.select_one(".result__title")
            s = r.select_one(".result__snippet")
            if t and s:
                results.append(f"• {t.get_text(strip=True)}: {s.get_text(strip=True)}")
        return "\n".join(results) or "No results found."
    except Exception as e:
        return f"Search error: {e}"

def _system_info(type_: str) -> str:
    data: dict = {}
    if type_ in ("cpu","all"):
        data["cpu_percent"] = psutil.cpu_percent(interval=0.5)
        data["cpu_count"]   = psutil.cpu_count()
    if type_ in ("ram","all"):
        r = psutil.virtual_memory()
        data["ram_total"]   = f"{r.total/1e9:.1f} GB"
        data["ram_used"]    = f"{r.used/1e9:.1f} GB"
        data["ram_percent"] = r.percent
    if type_ in ("disk","all"):
        d = psutil.disk_usage("/")
        data["disk_total"]  = f"{d.total/1e9:.1f} GB"
        data["disk_free"]   = f"{d.free/1e9:.1f} GB"
        data["disk_percent"]= d.percent
    if type_ in ("processes","all"):
        procs = []
        for p in sorted(psutil.process_iter(["pid","name","cpu_percent"]),
                        key=lambda x: x.info["cpu_percent"] or 0, reverse=True)[:8]:
            procs.append(f"{p.info['name']} (PID {p.info['pid']}, CPU {p.info['cpu_percent']}%)")
        data["top_processes"] = procs
    return json.dumps(data, indent=2)

async def _read_file(path: str) -> str:
    try:
        return Path(path).expanduser().read_text(encoding="utf-8", errors="replace")[:5000]
    except Exception as e:
        return f"Error: {e}"

async def _write_file(path: str, content: str) -> str:
    try:
        p = Path(path).expanduser()
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_text(content, encoding="utf-8")
        return f"Written to {path}."
    except Exception as e:
        return f"Error: {e}"

async def _research_safety(operation: str) -> str:
    results = await _search_web(f"risks of: {operation} linux safe?")
    return f"Online research on '{operation}':\n{results}"

# ─── Session ────────────────────────────────────────────────────────────────────
class AmaSession:
    def __init__(self, ws: WebSocket):
        self.ws = ws
        self.history: list[types.Content] = []
        self.pending_confirm: Optional[dict] = None
        self.camera_frame: Optional[str] = None

    async def send(self, msg: dict):
        await self.ws.send_json(msg)

    async def handle(self, data: dict):
        t = data.get("type")
        if t == "speech":
            await self.process(data.get("text","").strip())
        elif t == "camera_frame":
            self.camera_frame = data.get("image")
        elif t == "confirm_yes" and self.pending_confirm:
            cmd = self.pending_confirm["command"]
            self.pending_confirm = None
            await self.send({"type":"tool_start","name":"shell","command":cmd})
            out = await _run_shell(cmd)
            await self.send({"type":"tool_done","name":"shell","output":out})
            await self.send({"type":"response","text":f"Done. {out[:200]}","speak":True})
        elif t == "confirm_no":
            self.pending_confirm = None
            await self.send({"type":"response","text":"Okay, cancelled.","speak":True})

    async def process(self, text: str):
        if not text: return
        if not client:
            await self.send({"type":"response",
                "text":"Please set GEMINI_API_KEY to enable AI. Get a free key at aistudio.google.com",
                "speak":True})
            return

        await self.send({"type":"processing","active":True})
        try:
            # Build message
            self.history.append(types.Content(role="user",
                parts=[types.Part(text=text)]))

            response = client.models.generate_content(
                model=MODEL,
                contents=self.history,
                config=types.GenerateContentConfig(
                    system_instruction=SYSTEM_PROMPT,
                    tools=TOOLS,
                    temperature=0.7,
                )
            )
            await self._handle_response(response)
        except Exception as e:
            await self.send({"type":"response","text":f"Sorry, error: {e}","speak":True})
        finally:
            await self.send({"type":"processing","active":False})

    async def _handle_response(self, response):
        text_parts, tool_calls = [], []
        for part in response.candidates[0].content.parts:
            if part.text:
                text_parts.append(part.text)
            if part.function_call:
                tool_calls.append(part.function_call)

        if text_parts:
            txt = " ".join(text_parts)
            self.history.append(types.Content(role="model",
                parts=[types.Part(text=txt)]))
            await self.send({"type":"response","text":txt,"speak":True})

        if not tool_calls:
            return

        tool_results = []
        for fc in tool_calls:
            name = fc.name
            args = dict(fc.args)
            result = await self._execute_tool(name, args)
            if result == "__CONFIRM_PENDING__":
                return
            tool_results.append(types.Part(
                function_response=types.FunctionResponse(
                    name=name, response={"result": result}
                )
            ))

        # Feed results back
        self.history.append(types.Content(role="model",
            parts=[types.Part(function_call=fc) for fc in tool_calls]))
        self.history.append(types.Content(role="tool",
            parts=tool_results))

        follow = client.models.generate_content(
            model=MODEL,
            contents=self.history,
            config=types.GenerateContentConfig(
                system_instruction=SYSTEM_PROMPT,
                tools=TOOLS,
            )
        )
        await self._handle_response(follow)

    async def _execute_tool(self, name: str, args: dict) -> str:
        risk = args.get("risk_level", "low")
        await self.send({"type":"tool_start","name":name,"args":args})

        if name == "run_shell" and risk == "high":
            research = await _research_safety(args["command"])
            self.pending_confirm = {"command": args["command"]}
            await self.send({"type":"confirm_request","command":args["command"],
                             "research":research,"risk":"high"})
            return "__CONFIRM_PENDING__"

        if name == "run_shell" and risk == "medium":
            self.pending_confirm = {"command": args["command"]}
            await self.send({"type":"confirm_request","command":args["command"],
                             "research":None,"risk":"medium"})
            return "__CONFIRM_PENDING__"

        result = "Unknown tool."
        if   name == "run_shell":      result = await _run_shell(args["command"])
        elif name == "open_app":       result = await _open_app(args["target"])
        elif name == "search_web":     result = await _search_web(args["query"])
        elif name == "system_info":    result = _system_info(args["type"])
        elif name == "read_file":      result = await _read_file(args["path"])
        elif name == "write_file":     result = await _write_file(args["path"], args["content"])
        elif name == "research_safety":result = await _research_safety(args["operation"])

        await self.send({"type":"tool_done","name":name,"output":result[:500]})
        return result

# ─── FastAPI App ────────────────────────────────────────────────────────────────
app = FastAPI(title="Ama Home Assistant")
UI_FILE = Path(__file__).parent / "ui" / "index.html"

@app.get("/")
async def root():
    return HTMLResponse(UI_FILE.read_text(encoding="utf-8"))

@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket):
    await ws.accept()
    session = AmaSession(ws)
    try:
        while True:
            data = await ws.receive_json()
            await session.handle(data)
    except WebSocketDisconnect:
        pass
    except Exception as e:
        print(f"WS error: {e}")

# ─── Entry Point ────────────────────────────────────────────────────────────────
if __name__ == "__main__":
    import uvicorn
    hostname = socket.gethostname()
    try:
        local_ip = socket.gethostbyname(hostname)
    except Exception:
        local_ip = "unknown"

    print("\n" + "═"*50)
    print(f"  🏠  Ama — Personal AI Assistant")
    print("═"*50)
    print(f"  Local:    http://localhost:{PORT}")
    print(f"  Network:  http://{local_ip}:{PORT}")
    if not GEMINI_API_KEY:
        print("  ⚠️  No GEMINI_API_KEY! → https://aistudio.google.com/")
    print("═"*50 + "\n")

    uvicorn.run(app, host=HOST, port=PORT, log_level="warning")
