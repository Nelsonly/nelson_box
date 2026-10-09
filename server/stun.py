"""极简 STUN 服务（RFC 5389 Binding）

只回答“你的公网 IP 和端口是多少”，供 WebRTC 打洞使用。不转发任何数据。
"""
import asyncio
import ipaddress
import logging
import socket
import struct

log = logging.getLogger("nelsonbox.stun")

MAGIC_COOKIE = 0x2112A442
BINDING_REQUEST = 0x0001
BINDING_SUCCESS = 0x0101
ATTR_XOR_MAPPED_ADDRESS = 0x0020
ATTR_SOFTWARE = 0x8022


def build_response(request: bytes, addr) -> bytes | None:
    if len(request) < 20:
        return None
    msg_type, _length, cookie = struct.unpack("!HHI", request[:8])
    if msg_type != BINDING_REQUEST or cookie != MAGIC_COOKIE:
        return None
    txid = request[8:20]

    host, port = addr[0], addr[1]
    ip = ipaddress.ip_address(host.split("%")[0])
    if ip.version == 6 and ip.ipv4_mapped:
        ip = ip.ipv4_mapped
    xport = port ^ (MAGIC_COOKIE >> 16)
    if ip.version == 4:
        xaddr = struct.pack("!I", int(ip) ^ MAGIC_COOKIE)
        value = struct.pack("!BBH", 0, 0x01, xport) + xaddr
    else:
        key = int.from_bytes(struct.pack("!I", MAGIC_COOKIE) + txid, "big")
        xaddr = (int(ip) ^ key).to_bytes(16, "big")
        value = struct.pack("!BBH", 0, 0x02, xport) + xaddr

    attrs = struct.pack("!HH", ATTR_XOR_MAPPED_ADDRESS, len(value)) + value
    software = b"nelsonbox"
    software += b"\0" * (-len(software) % 4)
    attrs += struct.pack("!HH", ATTR_SOFTWARE, len(b"nelsonbox")) + software
    return struct.pack("!HHI", BINDING_SUCCESS, len(attrs), MAGIC_COOKIE) + txid + attrs


class StunProtocol(asyncio.DatagramProtocol):
    def connection_made(self, transport):
        self.transport = transport

    def datagram_received(self, data, addr):
        try:
            resp = build_response(data, addr)
        except Exception:
            return
        if resp:
            self.transport.sendto(resp, addr)


async def start_stun_server(port: int):
    """同时监听 IPv4 和 IPv6（如果系统支持）"""
    loop = asyncio.get_running_loop()
    transports = []
    for family, host in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET6, "::")):
        try:
            sock = socket.socket(family, socket.SOCK_DGRAM)
            if family == socket.AF_INET6:
                sock.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            sock.bind((host, port))
            transport, _ = await loop.create_datagram_endpoint(StunProtocol, sock=sock)
            transports.append(transport)
        except OSError as e:
            if family == socket.AF_INET:
                log.warning("STUN 监听 %s:%s 失败: %s", host, port, e)
    return transports

