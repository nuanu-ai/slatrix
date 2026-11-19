# /// script
# requires-python = ">=3.12,<3.13"
# dependencies = ["aiohttp==3.14.5", "matrix-synapse==1.165.0"]
# ///
"""uv run scripts/tests/delivery/probe.py [--seed N] [--rounds N]"""

import argparse
import asyncio
import json
import os
import random
import secrets
import subprocess
import sys
from contextlib import asynccontextmanager
from pathlib import Path
from tempfile import TemporaryDirectory
from urllib.parse import quote

from aiohttp import ClientConnectionError, ClientSession, UnixConnector, web
from yarl import URL

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
UPSTREAM = "http://localhost"
API = "/_matrix/client/v3"


@asynccontextmanager
async def homeserver(directory):
    # A Unix socket keeps registration and both synthetic accounts inside the fixture.
    socket_path = directory / "matrix.sock"
    config = {
        "server_name": "test.invalid",
        "report_stats": False,
        "listeners": [{"path": str(socket_path), "type": "http", "resources": [{"names": ["client"]}]}],
        "database": {"name": "sqlite3", "args": {"database": "homeserver.db"}},
        "enable_registration": True,
        "enable_registration_without_verification": True,
        "trusted_key_servers": [],
        "signing_key_path": "fixture.key",
        "macaroon_secret_key": secrets.token_hex(32),
        "rc_message": {"per_second": 1000, "burst_count": 1000},
        "rc_room_creation": {"per_second": 1000, "burst_count": 1000},
        "rc_joins": {"local": {"per_second": 1000, "burst_count": 1000}},
        "rc_invites": {
            key: {"per_second": 1000, "burst_count": 1000} for key in ("per_room", "per_user", "per_issuer")
        },
    }
    config_path = directory / "homeserver.yaml"
    config_path.write_text(json.dumps(config))
    with (directory / "synapse.log").open("w") as log:
        server = await asyncio.create_subprocess_exec(
            sys.executable,
            "-m",
            "synapse.app.homeserver",
            "-c",
            str(config_path),
            cwd=directory,
            stdout=log,
            stderr=log,
        )
        try:
            async with ClientSession(
                connector=UnixConnector(path=str(socket_path)), headers={"X-Forwarded-For": "127.0.0.1"}
            ) as http:
                async with asyncio.timeout(40):
                    while True:
                        if server.returncode is not None:
                            raise RuntimeError(f"Local Synapse exited during startup ({server.returncode})")
                        try:
                            async with http.get(UPSTREAM + "/_matrix/client/versions") as response:
                                response.raise_for_status()
                                break
                        except ClientConnectionError:
                            await asyncio.sleep(0.05)
                yield http
        finally:
            if server.returncode is None:
                server.kill()
            await server.wait()


async def matrix(http, method, path, token=None, data=None):
    headers = {"Authorization": "Bearer " + token} if token else {}
    async with http.request(method, UPSTREAM + API + path, headers=headers, json=data) as response:
        response.raise_for_status()
        return await response.json()


async def register(http, name):
    data = {
        "auth": {"type": "m.login.dummy"},
        "username": name,
        "password": secrets.token_hex(24),
        "device_id": name.upper(),
    }
    return (await matrix(http, "POST", "/register", data=data))["access_token"]


async def kill(process):
    if process.returncode is None:
        process.kill()
    await process.wait()


async def crash_case(http, sender, reader, binary, store, messages, target, committed, retry_body, fault):
    created = await matrix(http, "POST", "/createRoom", sender, {"invite": ["@reader:test.invalid"]})
    room = created["room_id"]
    room_path = "/rooms/" + quote(room, safe="")
    await matrix(http, "POST", room_path + "/join", reader, {})

    async def history():
        result = await matrix(http, "GET", room_path + "/messages?dir=b&limit=100", reader)
        return [e["content"]["body"] for e in reversed(result["chunk"]) if e["type"] == "m.room.message"]

    at_cut, release = asyncio.Event(), asyncio.Event()
    injected = False

    async def proxy(request):
        nonlocal injected
        payload = await request.read()
        outgoing = None
        if request.method == "PUT" and "/send/m.room.message/" in request.path:
            outgoing = json.loads(payload).get("body")
        cut = not at_cut.is_set() and outgoing == target
        retry_fault = release.is_set() and not injected and outgoing == retry_body
        if retry_fault and fault in ("503", "429"):
            injected = True
            if fault == "429":
                return web.json_response(
                    {"errcode": "M_LIMIT_EXCEEDED", "error": "Try again"},
                    status=429,
                    headers={"Retry-After": "0"},
                )
            return web.json_response({"errcode": "M_UNKNOWN", "error": "Unavailable"}, status=503)
        if cut and not committed:
            at_cut.set()
            await release.wait()
            return web.Response(status=503)
        headers = {k: v for k, v in request.headers.items() if k.lower() in ("authorization", "content-type")}
        async with http.request(
            request.method, URL(UPSTREAM + request.raw_path, encoded=True), headers=headers, data=payload
        ) as response:
            body = await response.read()
            if cut and response.status == 200:
                at_cut.set()
                await release.wait()
            if retry_fault and fault == "lost-ack" and response.status == 200:
                injected = True
                request.transport.abort()
            return web.Response(status=response.status, body=body, content_type="application/json")

    app = web.Application()
    app.router.add_route("*", "/{path:.*}", proxy)
    runner = web.AppRunner(app, handler_cancellation=True, shutdown_timeout=1)
    await runner.setup()
    process = None
    try:
        await web.TCPSite(runner, "127.0.0.1", 0).start()
        url = "http://127.0.0.1:" + str(runner.addresses[0][1])

        async def launch(mode, bodies):
            return await asyncio.create_subprocess_exec(
                binary,
                mode,
                url,
                room,
                store,
                *bodies,
                env={**os.environ, "DELIVERY_TEST_TOKEN": sender},
                stdin=asyncio.subprocess.PIPE,
                stdout=asyncio.subprocess.PIPE,
                stderr=asyncio.subprocess.DEVNULL,
            )

        async def enqueued(child):
            if await child.stdout.readline() != b"ENQUEUED\n":
                raise RuntimeError("SDK sender exited before accepting its messages")

        process = await launch("queue", messages)
        try:
            async with asyncio.timeout(45):
                await asyncio.gather(enqueued(process), at_cut.wait())
        except TimeoutError as error:
            raise TimeoutError(
                f"Did not reach the selected crash point (cut reached: {at_cut.is_set()})"
            ) from error
        await kill(process)
        release.set()
        prefix = messages[: messages.index(target) + int(committed)]
        seen = await history()
        if seen != prefix:
            raise AssertionError(f"At crash: reader saw {seen}, expected {prefix}")

        marker = "queue-drained"
        new_messages = ["after-restart", marker]
        process = await launch("restore", new_messages)
        try:
            async with asyncio.timeout(45):
                await enqueued(process)
                while marker not in (seen := await history()):
                    await asyncio.sleep(0.1)
        except TimeoutError as error:
            raise TimeoutError(f"Queue stalled after restart. Last history: {seen}") from error
        if not injected:
            raise AssertionError(f"Missed {fault} on {retry_body}")
        if seen != messages + new_messages:
            raise AssertionError(f"After restart: reader saw {seen}, expected {messages + new_messages}")
    finally:
        release.set()
        if process is not None:
            await kill(process)
        await runner.cleanup()


async def run(seed, rounds, binary):
    rng = random.Random(seed)
    with TemporaryDirectory(prefix="slatrix-", dir="/tmp") as tmp:
        async with homeserver(Path(tmp)) as http:
            sender, reader = await register(http, "sender"), await register(http, "reader")
            for number in range(rounds):
                count = rng.randint(3, 12)
                messages = [f"message-{i}" for i in range(count)]
                positions = (0, count // 2, count - 1)
                target = messages[positions[(number // 2) % len(positions)]]
                committed = bool(number % 2)
                retry_body = rng.choice(messages[messages.index(target) + 1 :] + ["after-restart"])
                fault = rng.choice(["429", "503", "lost-ack"])
                print(
                    f"seed={seed} case={number + 1} count={count} cut={target} committed={committed} retry={retry_body}:{fault}",
                    flush=True,
                )
                with TemporaryDirectory(dir=tmp) as store:
                    await crash_case(
                        http, sender, reader, binary, store, messages, target, committed, retry_body, fault
                    )
    print(f"{rounds} crash and restart cases passed")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(
        description="Crash and restart the pinned Matrix SDK against a private Synapse."
    )
    parser.add_argument("--seed", type=int, default=1)
    parser.add_argument("--rounds", type=int, default=6)
    args = parser.parse_args()
    if args.rounds < 1:
        parser.error("--rounds must be positive")
    subprocess.run([ROOT / "scripts/build-sdk.sh"], cwd=ROOT, check=True)
    build = ["swift", "build", "--package-path", str(HERE), "--disable-keychain"]
    subprocess.run(build, check=True)
    binary = Path(subprocess.check_output(build + ["--show-bin-path"], text=True).strip()) / "DeliverySender"
    asyncio.run(run(args.seed, args.rounds, binary))
