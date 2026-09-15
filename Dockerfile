# syntax=docker/dockerfile:1
# ============================================================================
#  ELMINYAWE Solver  v3.1.0  —  Single-Container Edition
# ----------------------------------------------------------------------------
#  Cloudflare Turnstile solving behind the ELMINYAWE API.
#  Engine: Theyka/Turnstile-Solver algorithm (patchright + Turnstile widget),
#          embedded here and hardened for Docker single-container use.
#
#  ONE image, ONE container, ALL code embedded in this file (heredocs).
#  Fully white-labeled: the API speaks ELMINYAWE only.
#
#  BUILD : docker build -t elminyawe-solver .
#  RUN   : docker run -d -p 8191:8191 --shm-size=256m elminyawe-solver
#
#  QUICK USE :
#    POST /v1     {"url": "https://site.com/page", "sitekey": "0x4AAA..."}
#    GET  /solve  /solve?url=https://site.com/page&sitekey=0x4AAA...
#    GET  /health
#  'sitekey' is optional: if omitted, the API fetches the target page and
#  tries to auto-detect the Turnstile widget settings (sitekey/action/cdata).
#  'secret' is optional: when given, the API validates the token through
#  Cloudflare siteverify and returns the verdict inline (result.siteverify).
#  Standalone validation:  GET/POST /siteverify  (token + secret).
#
#  ENV CONFIG (all optional):
#    PORT=8191                 API port
#    HOST=0.0.0.0              bind address
#    LOG_LEVEL=info            info | debug | warning | error
#    MAX_CONCURRENT_SOLVES=2   simultaneous browser sessions (RAM guard)
#    WORKER_WAIT_TIMEOUT=5     seconds a request waits for a free slot (then 503)
#    SOLVE_ATTEMPTS=10         widget polling attempts per solve (~2.5s each)
#    ELMINYAWE_UA=<chrome ua>  browser User-Agent (required for headless mode)
#    ELMINYAWE_HEADLESS=true   false = use the built-in virtual display (Xvfb)
#    PAGE_FETCH_TIMEOUT=15     seconds for the sitekey auto-detection fetch
# ============================================================================

FROM python:3.11-slim

ENV PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1 \
    DEBIAN_FRONTEND=noninteractive \
    HOST=0.0.0.0 \
    PORT=8191 \
    LOG_LEVEL=info \
    MAX_CONCURRENT_SOLVES=2 \
    WORKER_WAIT_TIMEOUT=5 \
    SOLVE_ATTEMPTS=10 \
    PAGE_FETCH_TIMEOUT=15 \
    ELMINYAWE_HEADLESS=true \
    TZ=UTC

# --- system: virtual display (optional headed mode) + fonts + certs ----------
RUN apt-get update \
 && apt-get install -y --no-install-recommends \
        xvfb \
        fonts-liberation \
        ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# --- engine driver (patchright) + API framework -------------------------------
RUN pip install --no-cache-dir patchright fastapi "uvicorn[standard]"

# --- browser used by the engine (with all its OS dependencies) ----------------
RUN python -m patchright install --with-deps chromium

WORKDIR /app

# ============================================================================
#  EMBEDDED FILE 1/3 : /app/elminyawe_engine.py
#  ELMINYAWE Turnstile engine — Theyka/Turnstile-Solver solving algorithm
#  (patchright stealth browser + local widget page + click loop), hardened:
#  Docker-safe flags, per-solve proxy, configurable attempts/UA/headless.
# ============================================================================
RUN cat > /app/elminyawe_engine.py <<'PY'
# ============================================================
#  ELMINYAWE Engine - Cloudflare Turnstile solving core (v3.1.0)
#  Algorithm: Theyka/Turnstile-Solver (patchright + Turnstile
#  widget injection + checkbox click loop).
#  ELMINYAWE hardening for single-container use:
#    - Docker-safe Chromium launch flags (--no-sandbox, --disable-dev-shm-usage)
#    - per-solve proxy support (parsed into patchright format)
#    - configurable attempts / user-agent / headless
# ============================================================
import os
import time
from dataclasses import dataclass
from typing import Optional
from urllib.parse import urlsplit

from patchright.sync_api import sync_playwright

DEFAULT_UA = os.environ.get(
    "ELMINYAWE_UA",
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
)
DEFAULT_ATTEMPTS = int(os.environ.get("SOLVE_ATTEMPTS", "10"))

# Flags that keep Chromium stable inside containers
DOCKER_ARGS = [
    "--no-sandbox",
    "--disable-dev-shm-usage",
    "--disable-gpu",
    "--disable-software-rasterizer",
    "--no-first-run",
    "--no-default-browser-check",
    "--window-size=1280,720",
]


@dataclass
class TurnstileResult:
    turnstile_value: Optional[str]
    elapsed_time_seconds: float
    status: str                    # success | failure | error
    reason: Optional[str] = None


def parse_proxy(proxy: Optional[str]) -> Optional[dict]:
    """
    Accepts:  host:port | scheme://host:port | scheme://user:pass@host:port
    Returns:  patchright proxy dict, or None when empty/invalid.
    """
    if not proxy or not str(proxy).strip():
        return None
    raw = str(proxy).strip()
    if "://" not in raw:
        raw = "http://" + raw
    try:
        parts = urlsplit(raw)
        if not parts.hostname:
            return None
        default_port = 443 if parts.scheme == "https" else 80
        server = f"{parts.scheme or 'http'}://{parts.hostname}:{parts.port or default_port}"
        out = {"server": server}
        if parts.username:
            out["username"] = parts.username
        if parts.password:
            out["password"] = parts.password
        return out
    except Exception:
        return None


class TurnstileSolver:
    """ELMINYAWE Turnstile engine (Theyka/Turnstile-Solver algorithm)."""

    HTML_TEMPLATE = """
    <!DOCTYPE html>
    <html lang="en">
    <head>
        <meta charset="UTF-8">
        <meta name="viewport" content="width=device-width, initial-scale=1.0">
        <title>ELMINYAWE</title>
        <script src="https://challenges.cloudflare.com/turnstile/v0/api.js" async></script>
        <script>
            async function fetchIP() {
                try {
                    const response = await fetch('https://api64.ipify.org?format=json');
                    const data = await response.json();
                    document.getElementById('ip-display').innerText = `Your IP: ${data.ip}`;
                } catch (error) {
                    console.error('Error fetching IP:', error);
                    document.getElementById('ip-display').innerText = 'Failed to fetch IP';
                }
            }
            window.onload = fetchIP;
        </script>
    </head>
    <body>
        <!-- cf turnstile -->
        <p id="ip-display">Fetching your IP...</p>
    </body>
    </html>
    """

    def __init__(self, headless: bool = True, useragent: Optional[str] = None,
                 browser_type: str = "chromium", attempts: Optional[int] = None):
        self.headless = bool(headless)
        self.useragent = useragent or DEFAULT_UA
        self.browser_type = browser_type
        self.attempts = max(1, int(attempts or DEFAULT_ATTEMPTS))
        self.browser_args = list(DOCKER_ARGS)
        if self.useragent:
            self.browser_args.append(f"--user-agent={self.useragent}")

    def solve(self, url: str, sitekey: str, action: Optional[str] = None,
              cdata: Optional[str] = None, proxy: Optional[str] = None) -> TurnstileResult:
        start_time = time.time()
        playwright = None
        browser = None
        try:
            playwright = sync_playwright().start()
            browser = playwright.chromium.launch(
                headless=self.headless,
                args=self.browser_args,
            )
            context = browser.new_context(proxy=parse_proxy(proxy))
            page = context.new_page()

            url_with_slash = url + "/" if not url.endswith("/") else url

            turnstile_div = (
                '<div class="cf-turnstile" style="background: white;" '
                f'data-sitekey="{sitekey}"'
                + (f' data-action="{action}"' if action else "")
                + (f' data-cdata="{cdata}"' if cdata else "")
                + "></div>"
            )
            page_data = self.HTML_TEMPLATE.replace("<!-- cf turnstile -->", turnstile_div)

            page.route(url_with_slash, lambda route: route.fulfill(body=page_data, status=200))
            page.goto(url_with_slash)

            # shrink the widget so the checkbox sits at a natural click position
            try:
                page.eval_on_selector(
                    "//div[@class='cf-turnstile']", "el => el.style.width = '70px'"
                )
            except Exception:
                pass

            turnstile_value = None
            for _ in range(self.attempts):
                try:
                    check = page.input_value("[name=cf-turnstile-response]", timeout=2000)
                    if check == "":
                        try:
                            page.locator("//div[@class='cf-turnstile']").click(timeout=1000)
                        except Exception:
                            pass
                        time.sleep(0.5)
                    else:
                        turnstile_value = check
                        break
                except Exception:
                    pass

            elapsed = round(time.time() - start_time, 3)
            if turnstile_value:
                return TurnstileResult(
                    turnstile_value=turnstile_value,
                    elapsed_time_seconds=elapsed,
                    status="success",
                )
            return TurnstileResult(
                turnstile_value=None,
                elapsed_time_seconds=elapsed,
                status="failure",
                reason="Max attempts reached without token retrieval",
            )
        except Exception as exc:
            elapsed = round(time.time() - start_time, 3)
            return TurnstileResult(
                turnstile_value=None,
                elapsed_time_seconds=elapsed,
                status="error",
                reason=f"{type(exc).__name__}: {exc}",
            )
        finally:
            for obj, meth in ((browser, "close"), (playwright, "stop")):
                if obj is not None:
                    try:
                        getattr(obj, meth)()
                    except Exception:
                        pass
PY

# ============================================================================
#  EMBEDDED FILE 2/3 : /app/elminyawe_api.py
#  The public ELMINYAWE API (FastAPI) — smart inspection, token-first responses.
# ============================================================================
RUN cat > /app/elminyawe_api.py <<'PY'
# ============================================================
#  ELMINYAWE Solver - Public API Gateway (v3.1.0)
#  Solves Cloudflare Turnstile challenges; the most important
#  values (the token) come FIRST in every response.
#
#  Endpoints:
#    GET  /                       -> service info
#    GET  /health                 -> health check
#    GET  /solve?url=&sitekey=&secret=  -> quick solve (both optional)
#    POST /v1 {url, sitekey?, action?, cdata?, proxy?, headless?,
#              useragent?, maxTimeout?, secret?}
#    GET/POST /siteverify {token, secret} -> validate any token through
#              Cloudflare siteverify and return the verdict
#
#  Fully white-labeled: everything appears as ELMINYAWE.
# ============================================================
import os
import re
import json
import time
import glob
import inspect
import logging
import ssl
import threading
import urllib.parse
import urllib.request
from typing import Optional

from fastapi import FastAPI, Request, Query
from fastapi.responses import JSONResponse
from fastapi.exceptions import RequestValidationError
from starlette.exceptions import HTTPException as StarletteHTTPException
from starlette.concurrency import run_in_threadpool

# --- engine (must be imported after the API's own config below) -------------
from elminyawe_engine import TurnstileSolver, DEFAULT_UA

VERSION = "3.1.0"
SERVICE_NAME = "ELMINYAWE Solver"

MAX_CONCURRENT = max(1, int(os.environ.get("MAX_CONCURRENT_SOLVES", "2")))
WORKER_WAIT = int(os.environ.get("WORKER_WAIT_TIMEOUT", "5"))
PAGE_FETCH_TIMEOUT = int(os.environ.get("PAGE_FETCH_TIMEOUT", "15"))
SITEVERIFY_TIMEOUT = int(os.environ.get("SITEVERIFY_TIMEOUT", "10"))
MAX_HTML_BYTES = 3_000_000
SITEVERIFY_MAX_BYTES = 1_000_000
# Cloudflare's documented behavior: Turnstile TEST sitekeys always return
# this exact dummy token (developers.cloudflare.com/turnstile/troubleshooting/testing)
DUMMY_TOKEN = "XXXX.DUMMY.TOKEN.XXXX"
SITEVERIFY_URL = "https://challenges.cloudflare.com/turnstile/v0/siteverify"
HEADLESS_DEFAULT = os.environ.get("ELMINYAWE_HEADLESS", "true").strip().lower() not in (
    "0", "false", "no", "off",
)

LOG_LEVEL = os.environ.get("LOG_LEVEL", "info").upper()
logging.basicConfig(
    level=getattr(logging, LOG_LEVEL, logging.INFO),
    format="%(asctime)s %(levelname)s %(message)s",
)
log = logging.getLogger("ELMINYAWE")

app = FastAPI(
    title=SERVICE_NAME,
    version=VERSION,
    docs_url=None,
    redoc_url=None,
    openapi_url=None,
)

_WORKERS = threading.BoundedSemaphore(MAX_CONCURRENT)

_UA = (
    "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 "
    "(KHTML, like Gecko) Chrome/126.0.0.0 Safari/537.36"
)

# ------------------------------------------------------------------
#  White-label safety: strip internal engine names from any message
# ------------------------------------------------------------------
_LEAKS = (
    ("TurnstileAPIServer", "elminyawe-engine"),
    ("TurnstileSolver", "ElminyaweSolver"),
    ("turnstile_solver", "elminyawe-engine"),
    ("turnstile-solver", "elminyawe-engine"),
    ("elminyawe_engine", "engine"),
    ("patchright", "engine"),
    ("Patchright", "engine"),
    ("playwright", "engine"),
    ("Playwright", "engine"),
    ("camoufox", "engine"),
    ("sync_solver", "engine"),
)


def _rebrand(text):
    if not isinstance(text, str):
        return text
    for leaked, branded in _LEAKS:
        text = text.replace(leaked, branded)
    return text


def _now_ms():
    return int(time.time() * 1000)


# ------------------------------------------------------------------
#  Smart inspection - find the Turnstile widget on the target page
# ------------------------------------------------------------------
RE_DATA_SITEKEY = re.compile(
    r"""data-sitekey\s*=\s*["']([0-9A-Za-z_\-]{20,60})["']""", re.I
)
RE_JSON_SITEKEY = re.compile(r""""sitekey"\s*:\s*"([0-9A-Za-z_\-]{20,60})""" , re.I)
RE_TURNSTILE_MARK = re.compile(
    r"""challenges\.cloudflare\.com/turnstile|cf-turnstile-response""", re.I
)
RE_ACTION = re.compile(r"""data-action\s*=\s*["']([^"']{1,120})["']""", re.I)
RE_CDATA = re.compile(r"""data-cdata\s*=\s*["']([^"']{1,300})["']""", re.I)
RE_WIDGET_ATTR = re.compile(
    r"""data-(theme|size|appearance|retry|refresh-expired)\s*=\s*["']([^"']{1,40})["']""",
    re.I,
)


def _fetch_page(url: str):
    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": _UA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        },
    )
    ctx = ssl.create_default_context()
    with urllib.request.urlopen(req, timeout=PAGE_FETCH_TIMEOUT, context=ctx) as resp:
        return int(resp.getcode() or 0), resp.read(MAX_HTML_BYTES).decode("utf-8", "replace")


def _inspect_page(url: str):
    """Fetch the target page and locate the Turnstile widget + its settings."""
    info = {
        "page_fetched": False,
        "has_turnstile": False,
        "sitekey": None,
        "sitekey_source": None,
        "widget": {},
    }
    try:
        code, html = _fetch_page(url)
        info["page_fetched"] = True
        info["http_status"] = code
    except Exception as exc:
        info["error"] = _rebrand(f"{type(exc).__name__}: {exc}")
        return info

    if RE_TURNSTILE_MARK.search(html):
        info["has_turnstile"] = True

    match = RE_DATA_SITEKEY.search(html)
    if match:
        info["sitekey"] = match.group(1)
        info["sitekey_source"] = "auto_detected:data-sitekey"
    else:
        match = RE_JSON_SITEKEY.search(html)
        if match:
            info["sitekey"] = match.group(1)
            info["sitekey_source"] = "auto_detected:embedded"

    for key, rx in (("action", RE_ACTION), ("cdata", RE_CDATA)):
        m = rx.search(html)
        if m:
            info["widget"][key] = m.group(1)
    for m in RE_WIDGET_ATTR.finditer(html):
        if m.group(1) not in info["widget"]:
            info["widget"][m.group(1)] = m.group(2)
    return info


# ------------------------------------------------------------------
#  Engine bridge
# ------------------------------------------------------------------
def _solve_turnstile(url, sitekey, action=None, cdata=None, proxy=None,
                     headless=True, useragent=None, attempts=None):
    solver = TurnstileSolver(
        headless=headless,
        useragent=useragent,
        attempts=attempts,
    )
    return solver.solve(url=url, sitekey=sitekey, action=action,
                        cdata=cdata, proxy=proxy)


# ------------------------------------------------------------------
#  Server-side validation through Cloudflare siteverify (optional)
# ------------------------------------------------------------------
def _siteverify(token, secret):
    """Validate a Turnstile token server-side via Cloudflare siteverify."""
    t0 = _now_ms()
    data = urllib.parse.urlencode({
        "secret": str(secret),
        "response": str(token),
    }).encode("utf-8")
    try:
        req = urllib.request.Request(
            SITEVERIFY_URL,
            data=data,
            headers={
                "Content-Type": "application/x-www-form-urlencoded",
                "User-Agent": _UA,
            },
            method="POST",
        )
        ctx = ssl.create_default_context()
        with urllib.request.urlopen(
            req, timeout=SITEVERIFY_TIMEOUT, context=ctx
        ) as resp:
            payload = json.loads(
                resp.read(SITEVERIFY_MAX_BYTES).decode("utf-8", "replace")
            )
        if not isinstance(payload, dict):
            raise ValueError("siteverify returned a non-object payload")
        out = {
            "success": bool(payload.get("success")),
            "challenge_ts": payload.get("challenge_ts"),
            "hostname": payload.get("hostname"),
            "error_codes": payload.get("error-codes") or [],
        }
        if payload.get("messages"):
            out["messages"] = payload["messages"]
        if isinstance(payload.get("metadata"), dict):
            out["metadata"] = payload["metadata"]
        out["verified_in_ms"] = _now_ms() - t0
        return out
    except Exception as exc:
        return {
            "success": None,
            "error": _rebrand(f"{type(exc).__name__}: {exc}"),
            "verified_in_ms": _now_ms() - t0,
        }


# ------------------------------------------------------------------
#  Response builders (ELMINYAWE envelope, token first)
# ------------------------------------------------------------------
def _ok_body(url, sitekey, sitekey_source, token, widget, action, cdata,
             proxy, headless, useragent, started, engine_result,
             siteverify=None):
    ended = _now_ms()
    result = {
        "token": token,
        "cf_tokens": {"cf-turnstile-response": token},
    }
    if siteverify is not None:
        result["siteverify"] = siteverify
    result.update({
        "url": url,
        "sitekey": sitekey,
        "sitekey_source": sitekey_source,
        "challenge_solved": True,
        "action": action,
        "cdata": cdata,
        "proxy": proxy or None,
        "user_agent": useragent,
        "browser_type": "chromium",
        "headless": bool(headless),
        "widget": widget or {},
        "timing": {
            "solve_seconds": engine_result.elapsed_time_seconds,
            "total_ms": ended - started,
        },
    })
    if token.upper() == DUMMY_TOKEN:
        result["token_type"] = "cloudflare_dummy_token"
        result["note"] = (
            "This is Cloudflare's official DUMMY token: the target page uses a "
            "Turnstile TEST sitekey (e.g. 1x00000000000000000000AA). Cloudflare's "
            "documentation defines test sitekeys to always return "
            "'XXXX.DUMMY.TOKEN.XXXX', so this token proves the whole solving "
            "pipeline works. Dummy tokens are only accepted by Cloudflare TEST "
            "secret keys; real sitekeys produce production tokens that start "
            "with '0.'"
        )
    elif not token.startswith("0."):
        result["warning"] = (
            "token format looks unusual "
            "(Turnstile tokens normally start with '0.')"
        )
    return {
        "status": "ok",
        "message": "Challenge solved!",
        "start_timestamp": started,
        "end_timestamp": ended,
        "version": VERSION,
        "result": result,
        "solution": {
            "token": token,
            "turnstile_response": token,
            "url": url,
            "sitekey": sitekey,
        },
    }


def _error_body(message, started, err_type=None, detail=None, extra=None):
    ended = _now_ms()
    body = {
        "status": "error",
        "message": _rebrand(message),
        "start_timestamp": started,
        "end_timestamp": ended,
        "version": VERSION,
    }
    if err_type:
        body["error"] = {
            "type": err_type,
            "detail": _rebrand(detail) if detail else None,
        }
    if extra:
        body["result"] = extra
    return body


# ------------------------------------------------------------------
#  Shared handler for GET /solve and POST /v1
# ------------------------------------------------------------------
def _handle(url, sitekey=None, action=None, cdata=None, proxy=None,
            headless=None, useragent=None, max_timeout=None, secret=None):
    started = _now_ms()
    try:
        if not url or not re.match(r"^https?://", str(url).strip(), re.I):
            return (_error_body(
                "A valid 'url' (http/https) is required",
                started, "InvalidInput"), 400)
        url = str(url).strip()

        if isinstance(proxy, dict):
            proxy = proxy.get("url") or proxy.get("server") or None
        if proxy is not None:
            proxy = str(proxy).strip() or None

        sitekey_source = "provided"
        widget = {}
        if sitekey:
            sitekey = str(sitekey).strip()
        else:
            log.info("sitekey not provided -> smart inspection: %s", url)
            info = _inspect_page(url)
            widget = dict(info.get("widget") or {})
            if info.get("sitekey"):
                sitekey = info["sitekey"]
                sitekey_source = info.get("sitekey_source") or "auto_detected"
                log.info("auto-detected sitekey: %s...", sitekey[:12])
            else:
                reason = (
                    "target page could not be fetched"
                    if not info.get("page_fetched")
                    else "no Turnstile widget found on the page"
                )
                extra = {
                    "url": url,
                    "inspection": {
                        k: v for k, v in info.items() if k != "sitekey"
                    },
                }
                return (_error_body(
                    "Sitekey is required and auto-detection failed: "
                    f"{reason}. Pass 'sitekey' explicitly.",
                    started, "SitekeyNotFound", extra=extra), 422)

        if not action and widget.get("action"):
            action = widget.get("action")
        if not cdata and widget.get("cdata"):
            cdata = widget.get("cdata")

        attempts = None
        if max_timeout:
            try:
                attempts = max(3, min(int(round(int(max_timeout) / 2500)), 40))
            except Exception:
                attempts = None

        effective_ua = useragent or DEFAULT_UA
        headless = HEADLESS_DEFAULT if headless is None else bool(headless)

        if not _WORKERS.acquire(timeout=WORKER_WAIT):
            return (_error_body(
                "Solver busy: all worker slots are in use, retry shortly",
                started, "Busy"), 503)
        try:
            log.info("solving: %s | sitekey=%s... | action=%s | proxy=%s",
                     url, (sitekey or "?")[:12], action or "-", bool(proxy))
            engine_result = _solve_turnstile(
                url=url, sitekey=sitekey, action=action, cdata=cdata,
                proxy=proxy, headless=headless,
                useragent=useragent, attempts=attempts,
            )
        finally:
            _WORKERS.release()

        token = (engine_result.turnstile_value or "").strip()
        if engine_result.status == "success" and token and len(token) >= 20:
            log.info("solved in %ss (token=%s...)",
                     engine_result.elapsed_time_seconds, token[:12])
            verify_block = None
            if secret:
                log.info("validating the token through Cloudflare siteverify")
                verify_block = _siteverify(token, str(secret).strip())
            body = _ok_body(url=url, sitekey=sitekey,
                            sitekey_source=sitekey_source, token=token,
                            widget=widget, action=action, cdata=cdata,
                            proxy=proxy, headless=headless,
                            useragent=effective_ua, started=started,
                            engine_result=engine_result,
                            siteverify=verify_block)
            return body, 200

        if engine_result.status == "failure":
            code, err_type = 504, "SolveTimeout"
        elif engine_result.status == "error":
            code, err_type = 502, "EngineError"
        else:
            code, err_type = 502, "InvalidToken"
        message = engine_result.reason or "the engine returned an empty or invalid token"
        detail = (f"token={token!r}" if err_type == "InvalidToken" else message)
        return (_error_body(f"Could not solve the challenge: {message}",
                            started, err_type, detail=detail), code)

    except Exception as exc:
        log.exception("unexpected error")
        return (_error_body(
            f"Unexpected internal error: {type(exc).__name__}: {exc}",
            started, "InternalError"), 500)


# ------------------------------------------------------------------
#  Browser availability (for /health)
# ------------------------------------------------------------------
def _browser_info():
    cache = os.path.expanduser("~/.cache/ms-playwright")
    hits = sorted(glob.glob(os.path.join(cache, "chromium-*")))
    if hits:
        return True, os.path.basename(hits[-1])
    return False, "chromium browser not found (patchright install missing)"


_BROWSER_OK, _BROWSER_DETAIL = _browser_info()


# ------------------------------------------------------------------
#  Endpoints
# ------------------------------------------------------------------
@app.get("/")
def root():
    return {
        "name": SERVICE_NAME,
        "version": VERSION,
        "status": "ok",
        "endpoints": {
            "GET /": "service information (this page)",
            "GET /health": "health check",
            "GET /solve": ("quick solve: /solve?url=<page>&sitekey=<optional>"
                           "&action=<optional>&cdata=<optional>&proxy=<optional>"
                           "&secret=<optional: validate the token via siteverify>"),
            "POST /v1": ("full solve body: {\"url\": ..., \"sitekey\"?: ..., "
                         "\"action\"?: ..., \"cdata\"?: ..., \"proxy\"?: ..., "
                         "\"headless\"?: true, \"useragent\"?: ..., "
                         "\"maxTimeout\"?: 60000, \"secret\"?: ...}"),
            "GET /siteverify": ("validate any token: "
                                "/siteverify?token=<token>&secret=<secret>"),
            "POST /siteverify": ("validate any token: "
                                 "{\"token\": ..., \"secret\": ...}"),
        },
    }


@app.get("/health")
def health():
    return {
        "status": "ok" if _BROWSER_OK else "degraded",
        "browser": _BROWSER_DETAIL,
        "engine_ready": _BROWSER_OK,
        "max_concurrent": MAX_CONCURRENT,
        "version": VERSION,
    }


@app.get("/solve")
def solve_get(
    url: str = Query(...),
    sitekey: Optional[str] = Query(None),
    action: Optional[str] = Query(None),
    cdata: Optional[str] = Query(None),
    proxy: Optional[str] = Query(None),
    headless: Optional[bool] = Query(None),
    useragent: Optional[str] = Query(None),
    maxTimeout: Optional[int] = Query(None),
    secret: Optional[str] = Query(None),
):
    body, code = _handle(url, sitekey=sitekey, action=action, cdata=cdata,
                         proxy=proxy, headless=headless, useragent=useragent,
                         max_timeout=maxTimeout, secret=secret)
    return JSONResponse(status_code=code, content=body)


@app.post("/v1")
async def v1(request: Request):
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    # the engine (patchright sync) must NOT run inside the event loop:
    # solve in the worker threadpool, exactly like the container did before
    body, code = await run_in_threadpool(
        _handle,
        payload.get("url") or payload.get("u"),
        sitekey=payload.get("sitekey") or payload.get("siteKey") or payload.get("site_key"),
        action=payload.get("action"),
        cdata=payload.get("cdata"),
        proxy=payload.get("proxy"),
        headless=payload.get("headless"),
        useragent=payload.get("useragent") or payload.get("user_agent"),
        max_timeout=payload.get("maxTimeout") or payload.get("max_timeout"),
        secret=payload.get("secret") or payload.get("siteverify_secret"),
    )
    return JSONResponse(status_code=code, content=body)


# ------------------------------------------------------------------
#  Standalone token validation (Cloudflare siteverify)
# ------------------------------------------------------------------
def _verify_handle(token, secret):
    started = _now_ms()
    if not token or not str(token).strip():
        return (_error_body("A 'token' is required to verify",
                            started, "InvalidInput"), 400)
    if not secret or not str(secret).strip():
        return (_error_body(
            "A 'secret' is required (the Turnstile secret key paired with the sitekey)",
            started, "InvalidInput"), 400)
    token = str(token).strip()
    verdict = _siteverify(token, str(secret).strip())
    if verdict.get("success") is None:
        return (_error_body(
            "Could not reach Cloudflare siteverify, try again",
            started, "SiteverifyUnreachable", detail=verdict.get("error"),
            extra={"token": token}), 502)
    accepted = bool(verdict.get("success"))
    body = {
        "status": "ok" if accepted else "error",
        "message": ("Token accepted by Cloudflare siteverify" if accepted
                    else "Token rejected by Cloudflare siteverify"),
        "start_timestamp": started,
        "end_timestamp": _now_ms(),
        "version": VERSION,
        "result": {
            "token": token,
            "siteverify": verdict,
        },
    }
    if token.upper() == DUMMY_TOKEN:
        body["result"]["token_type"] = "cloudflare_dummy_token"
    return body, 200


@app.get("/siteverify")
def siteverify_get(
    token: str = Query(...),
    secret: str = Query(...),
):
    body, code = _verify_handle(token, secret)
    return JSONResponse(status_code=code, content=body)


@app.post("/siteverify")
async def siteverify_post(request: Request):
    try:
        payload = await request.json()
    except Exception:
        payload = {}
    if not isinstance(payload, dict):
        payload = {}
    body, code = await run_in_threadpool(
        _verify_handle,
        payload.get("token") or payload.get("response"),
        payload.get("secret"),
    )
    return JSONResponse(status_code=code, content=body)


# ------------------------------------------------------------------
#  White-labeled error handlers
# ------------------------------------------------------------------
@app.exception_handler(StarletteHTTPException)
async def _http_error(request, exc):
    return JSONResponse(
        status_code=exc.status_code,
        content={
            "status": "error",
            "message": _rebrand(str(exc.detail)),
            "version": VERSION,
        },
    )


@app.exception_handler(RequestValidationError)
async def _validation_error(request, exc):
    return JSONResponse(
        status_code=400,
        content={
            "status": "error",
            "message": "Invalid request parameters: a valid 'url' is required",
            "version": VERSION,
        },
    )


log.info("%s v%s ready | browser: %s | max_concurrent=%d",
         SERVICE_NAME, VERSION, _BROWSER_DETAIL, MAX_CONCURRENT)
PY

# ============================================================================
#  EMBEDDED FILE 3/3 : /app/start_elminyawe.sh
#  Entrypoint — optional virtual display, preflight checks, single process.
# ============================================================================
RUN cat > /app/start_elminyawe.sh <<'SH'
#!/usr/bin/env bash
# ============================================================
#  ELMINYAWE Solver - container entrypoint (embedded)
#  Single process: the ELMINYAWE API. The engine runs inside
#  it (one isolated Chromium per solve).
# ============================================================
set -e
cd /app
export PYTHONPATH=/app
export PYTHONUNBUFFERED=1

HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8191}"

echo "[ELMINYAWE] Solver v3.1.0 - starting"

# optional headed (stealth) mode: serve the browser a virtual display
if [ "${ELMINYAWE_HEADLESS:-true}" = "false" ] && [ -z "${DISPLAY:-}" ]; then
  if command -v Xvfb >/dev/null 2>&1; then
    Xvfb :99 -screen 0 1280x720x24 >/dev/null 2>&1 &
    export DISPLAY=:99
    echo "[ELMINYAWE] virtual display ready on :99 (headless disabled)"
  else
    echo "[ELMINYAWE] WARNING: Xvfb not found, staying headless"
  fi
fi

# preflight: engine driver + browser availability (non-fatal warnings)
python - <<'PY'
import glob, os
try:
    import patchright  # noqa: F401
    print("[ELMINYAWE] engine driver: ready")
except Exception as exc:
    print(f"[ELMINYAWE] WARNING: engine driver import failed: {exc}")
cache = os.path.expanduser("~/.cache/ms-playwright")
hits = sorted(glob.glob(os.path.join(cache, "chromium-*")))
if hits:
    print(f"[ELMINYAWE] browser: ready -> {os.path.basename(hits[-1])}")
else:
    print("[ELMINYAWE] WARNING: chromium not found in patchright cache")
PY

echo "[ELMINYAWE] API listening on ${HOST}:${PORT}"
exec python -m uvicorn elminyawe_api:app --host "$HOST" --port "$PORT" --workers 1
SH
RUN chmod +x /app/start_elminyawe.sh

EXPOSE 8191

HEALTHCHECK --interval=30s --timeout=5s --start-period=15s --retries=3 \
  CMD python -c "import urllib.request as u,sys,os; r=u.urlopen('http://127.0.0.1:'+os.environ.get('PORT','8191')+'/health',timeout=4); sys.exit(0 if r.getcode()==200 else 1)" || exit 1

CMD ["/app/start_elminyawe.sh"]
