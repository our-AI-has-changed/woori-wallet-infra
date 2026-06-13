import ipaddress
import os


ALLOWED_NETWORKS = [
    ipaddress.ip_network(value.strip())
    for value in os.environ.get("ALLOWED_CIDRS", "").split(",")
    if value.strip()
]


def handler(event, _context):
    source_ip = (
        event.get("requestContext", {})
        .get("http", {})
        .get("sourceIp")
    )

    if not source_ip:
        return {"isAuthorized": False}

    try:
        client_ip = ipaddress.ip_address(source_ip)
    except ValueError:
        return {"isAuthorized": False}

    return {
        "isAuthorized": any(client_ip in network for network in ALLOWED_NETWORKS)
    }
