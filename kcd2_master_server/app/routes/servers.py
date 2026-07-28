from datetime import datetime, timedelta

from flask import Blueprint, request, jsonify
from app import db
from app.models import Server, Tag

servers_bp = Blueprint("servers", __name__)
MAX_TAGS = 3

# A relay re-registers on a timer, so a listing that has not been refreshed
# within this window is treated as gone. Without it the browser accumulates
# every relay that ever started, because nothing tells the master when one
# stops -- a crashed relay cannot deregister itself.
STALE_AFTER = timedelta(minutes=5)


@servers_bp.route("/servers_list", methods=["GET"])
def get_servers():
    query = Server.query
    if request.args.get("all") != "1":
        query = query.filter(Server.last_seen >= datetime.utcnow() - STALE_AFTER)
    return jsonify([s.to_dict() for s in query.all()])

@servers_bp.route("/get_server/<string:ip_address>", methods=["GET"])
def get_server(ip_address):
    server = Server.query.filter_by(ip_address=ip_address).first()

    if not server:
        return jsonify({
            "error": "Server not found"
            }),404

    return jsonify(server.detailed_dict())

@servers_bp.route("/register", methods=["POST"])
def register_servers():
    data = request.get_json(silent=True)
    if not isinstance(data, dict):
        return jsonify({"error": "Expected a JSON object"}), 400

    # "or []" rather than a default, so an explicit null is handled too.
    tag_names = data.get("tags") or []
    if not isinstance(tag_names, list):
        return jsonify({"error": "tags must be a list"}), 400

    if len(tag_names) > MAX_TAGS:
        return jsonify({"error": f"Max {MAX_TAGS} tags allowed"}), 400

    tags = Tag.query.filter(Tag.name.in_(tag_names)).all()

    if len(tags) != len(set(tag_names)):
        valid = [t.name for t in Tag.query.all()]
        return jsonify({"error": "Invalid tags", "allowed": valid}), 400

    # A relay behind NAT does not know the address peers reach it on, so the
    # address the request actually arrived from is the better default. An
    # explicit ip_address still wins, for a relay published under a fixed one.
    ip_address = data.get("ip_address") or request.remote_addr
    if not ip_address:
        return jsonify({"error": "ip_address is required and could not be inferred"}), 400

    try:
        port = int(data["port"])
        name = data["name"]
        map_name = data["map_name"]
    except (KeyError, TypeError, ValueError):
        return jsonify({"error": "name, port and map_name are required"}), 400

    # Registration doubles as the heartbeat, so it has to be an upsert keyed on
    # the address peers connect to. Inserting unconditionally meant every relay
    # restart added another row for the same server.
    server = Server.query.filter_by(ip_address=ip_address, port=port).first()
    created = server is None

    if created:
        server = Server(ip_address=ip_address, port=port)
        db.session.add(server)
    else:
        # An existing listing may only be refreshed by whoever created it. A
        # caller that omits the token is accepted because the first
        # registration has none to present, and the address it arrived from
        # already had to match.
        presented = data.get("token")
        if presented and presented != server.token:
            return jsonify({"error": "Token does not match the registered server"}), 403

    server.name = name
    server.map_name = map_name
    server.description = data.get("description")
    server.tags = tags
    server.last_seen = datetime.utcnow()

    db.session.commit()

    return jsonify({
        "message": "Server registered" if created else "Server refreshed",
        "id": server.id,
        "token": server.token
        }), 201 if created else 200
