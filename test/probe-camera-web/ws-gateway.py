#!/usr/bin/env python3
"""ws-gateway.py <listen host:port> <rdp host:port>: the page's gateway on a CI runner where
websockify does not install (Windows on Arm: its cryptography dependency has no wheel there and
no OpenSSL to build from source, run 46139068111). CI only, never shipped.

A WebSocket server (the "binary" subprotocol, as the client is linked with
-sWEBSOCKET_SUBPROTOCOL=binary) on <listen>, one TCP connection to <rdp> per WebSocket, bytes
passed both ways as they come, as websockify does. Needs the pure-Python websockets package."""
import asyncio
import sys

import websockets


def split(hostport):
    host, port = hostport.rsplit(":", 1)
    return host, int(port)


LISTEN = split(sys.argv[1])
TARGET = split(sys.argv[2])


async def bridge(ws):
    reader, writer = await asyncio.open_connection(*TARGET)
    print(f"connection: {ws.remote_address} -> {TARGET[0]}:{TARGET[1]}", flush=True)

    async def up():
        async for message in ws:
            writer.write(message if isinstance(message, bytes) else message.encode())
            await writer.drain()
        writer.close()

    async def down():
        while True:
            data = await reader.read(65536)
            if not data:
                break
            await ws.send(data)
        await ws.close()

    done, pending = await asyncio.wait([asyncio.create_task(up()), asyncio.create_task(down())],
                                       return_when=asyncio.FIRST_COMPLETED)
    for task in pending:
        task.cancel()
    writer.close()
    print(f"closed: {ws.remote_address}", flush=True)


async def main():
    async with websockets.serve(bridge, LISTEN[0], LISTEN[1], subprotocols=["binary"],
                                max_size=None, compression=None):
        print(f"listening on {LISTEN[0]}:{LISTEN[1]} for {TARGET[0]}:{TARGET[1]}", flush=True)
        await asyncio.Future()


asyncio.run(main())
