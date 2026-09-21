"""Minimal Flask app for the ECS Fargate demo (Tier 2).

Exposes GET /courses/count, backed by a MySQL RDS table (Tier 3).
On startup it creates the "courses" table and seeds one row if the table is
empty, so the demo works right after the first deploy with no manual SQL step.

DB connection details arrive as environment variables, set by the ECS task
definition (see src/infra/modules/ecs/main.tf).
"""
import os

import pymysql
from flask import Flask, jsonify

app = Flask(__name__)

# Read DB connection settings from env vars injected by ECS at container start.
DB_HOST = os.environ["DB_HOST"]
DB_PORT = int(os.environ.get("DB_PORT", 3306))
DB_NAME = os.environ["DB_NAME"]
DB_USER = os.environ["DB_USER"]
DB_PASSWORD = os.environ["DB_PASSWORD"]

CHANNEL = "everythingAWS"
DEFAULT_COUNT = 42  # seed value, inserted once if the table is empty


def get_connection():
    """Open a fresh DB connection. Simplest option for a low-traffic demo
    (no connection pooling needed)."""
    return pymysql.connect(
        host=DB_HOST,
        port=DB_PORT,
        user=DB_USER,
        password=DB_PASSWORD,
        database=DB_NAME,
        autocommit=True,
    )


def ensure_seeded():
    """Create the "courses" table if it doesn't exist yet, and insert one
    seed row if the table is empty. Runs once at container startup."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                """
                CREATE TABLE IF NOT EXISTS courses (
                    id INT AUTO_INCREMENT PRIMARY KEY,
                    channel VARCHAR(100) NOT NULL,
                    course_count INT NOT NULL
                )
                """
            )
            cur.execute("SELECT COUNT(*) FROM courses")
            (row_count,) = cur.fetchone()
            if row_count == 0:
                cur.execute(
                    "INSERT INTO courses (channel, course_count) VALUES (%s, %s)",
                    (CHANNEL, DEFAULT_COUNT),
                )
    finally:
        conn.close()


@app.route("/courses/count", methods=["GET"])
def courses_count():
    """Reads the current course count from RDS and returns it as JSON."""
    conn = get_connection()
    try:
        with conn.cursor() as cur:
            cur.execute(
                "SELECT course_count FROM courses WHERE channel = %s", (CHANNEL,)
            )
            row = cur.fetchone()
    finally:
        conn.close()
    return jsonify(channel=CHANNEL, courseCount=row[0])


if __name__ == "__main__":
    ensure_seeded()  # make sure the table/row exist before we start serving traffic
    app.run(host="0.0.0.0", port=5000)
