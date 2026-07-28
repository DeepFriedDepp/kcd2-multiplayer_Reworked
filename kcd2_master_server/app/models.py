from app import db
from datetime import datetime
import secrets

server_tags = db.Table(
        "server_tags",
        db.Column("server_id", db.Integer, db.ForeignKey("servers.id"), primary_key=True),
        db.Column("tag_id", db.Integer, db.ForeignKey("tags.id"), primary_key=True)
)

class Tag(db.Model):
    __tablename__ = "tags"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(50), unique=True, nullable=False)

class Server(db.Model):
    __tablename__ = "servers"

    id = db.Column(db.Integer, primary_key=True)
    name = db.Column(db.String(100), nullable=False)
    ip_address = db.Column(db.String(45), nullable=False)
    port = db.Column(db.Integer, nullable=False)
    map_name = db.Column(db.String(100), nullable=False)
    token = db.Column(db.String(64), unique=True, default=lambda: secrets.token_hex(32))
    created_at = db.Column(db.DateTime, default=datetime.utcnow)
    # Refreshed by every /register call, which a relay repeats on a timer. The
    # listing endpoint uses it to hide relays that have stopped answering.
    last_seen = db.Column(db.DateTime, default=datetime.utcnow, nullable=False)
    description = db.Column(db.Text, nullable=True)
    tags = db.relationship("Tag", secondary=server_tags, backref="servers")

    # One server per address, so re-registering refreshes the listing instead of
    # adding a duplicate.
    __table_args__ = (db.UniqueConstraint("ip_address", "port", name="uq_server_address"),)

    def to_dict(self):
        return {
                "id": self.id,
                "name": self.name,
                "ip_address": self.ip_address,
                "port": self.port,
                "map_name": self.map_name,
                "created_at": self.created_at.isoformat(),
                "last_seen": self.last_seen.isoformat(),
                "tags": [t.name for t in self.tags],
                }

    def detailed_dict(self):
        return {
                **self.to_dict(),
                "description": self.description,
                }

def seed_tags():
    allowed = ["PvP", "PvE", "RP", "Hardcore", "Friendly", "Modded"]
    for name in allowed:
        if not Tag.query.filter_by(name=name).first():
            db.session.add(Tag(name=name))
    db.session.commit()
