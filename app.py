"""
FRAUD DETECTION ENGINE
File: backend/app.py

Flask API that connects the Oracle DB to the frontend UI.
Install dependencies: pip install flask cx_Oracle flask-cors

Oracle Instant Client must be installed and cx_Oracle configured.
Update DB_CONFIG below with your Oracle credentials.
"""

from flask import Flask, jsonify, request, render_template
from flask_cors import CORS
import cx_Oracle
from datetime import datetime
import os

app = Flask(__name__, template_folder='../frontend/templates',
            static_folder='../frontend/static')
CORS(app)

# ── Oracle connection config ──────────────────────────────────────
DB_CONFIG = {
    "user":     os.getenv("ORACLE_USER", "your_username"),
    "password": os.getenv("ORACLE_PASS", "your_password"),
    "dsn":      os.getenv("ORACLE_DSN",  "localhost:1521/XE"),  # or your service name
}

def get_conn():
    return cx_Oracle.connect(**DB_CONFIG)

def rows_to_dict(cursor):
    """Convert cx_Oracle cursor rows to list of dicts."""
    cols = [col[0].lower() for col in cursor.description]
    return [dict(zip(cols, row)) for row in cursor.fetchall()]

# ── Health check ──────────────────────────────────────────────────
@app.route("/api/health")
def health():
    try:
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("SELECT 1 FROM DUAL")
        return jsonify({"status": "ok", "db": "connected"})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 500

# ── Dashboard summary ─────────────────────────────────────────────
@app.route("/api/dashboard")
def dashboard():
    with get_conn() as conn:
        cur = conn.cursor()

        cur.execute("SELECT COUNT(*) FROM transactions WHERE status='PENDING'")
        pending = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM transactions WHERE status IN ('FLAGGED','BLOCKED')")
        flagged = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM fraud_alerts WHERE resolved='N'")
        open_alerts = cur.fetchone()[0]

        cur.execute("SELECT COUNT(*) FROM accounts WHERE status='FROZEN'")
        frozen = cur.fetchone()[0]

        cur.execute("""
            SELECT alert_type, COUNT(*) as cnt
            FROM fraud_alerts
            GROUP BY alert_type
            ORDER BY cnt DESC
        """)
        alert_breakdown = rows_to_dict(cur)

        cur.execute("""
            SELECT TO_CHAR(CAST(txn_time AS DATE),'DD-MON') as day,
                   COUNT(*) as total,
                   SUM(CASE WHEN status IN ('FLAGGED','BLOCKED') THEN 1 ELSE 0 END) as suspicious
            FROM transactions
            WHERE txn_time >= SYSDATE - 7
            GROUP BY TO_CHAR(CAST(txn_time AS DATE),'DD-MON')
            ORDER BY MIN(txn_time)
        """)
        weekly_trend = rows_to_dict(cur)

    return jsonify({
        "pending": pending,
        "flagged": flagged,
        "open_alerts": open_alerts,
        "frozen_accounts": frozen,
        "alert_breakdown": alert_breakdown,
        "weekly_trend": weekly_trend
    })

# ── All transactions ───────────────────────────────────────────────
@app.route("/api/transactions")
def transactions():
    status_filter = request.args.get("status", None)
    account_filter = request.args.get("account_id", None)

    sql = """
        SELECT t.txn_id, t.account_id, c.full_name, t.txn_type,
               t.amount, t.merchant, t.location_city,
               TO_CHAR(t.txn_time,'YYYY-MM-DD HH24:MI:SS') as txn_time,
               t.status, t.channel
        FROM transactions t
        JOIN accounts a ON t.account_id = a.account_id
        JOIN customers c ON a.customer_id = c.customer_id
        WHERE 1=1
    """
    params = {}
    if status_filter:
        sql += " AND t.status = :status"
        params["status"] = status_filter.upper()
    if account_filter:
        sql += " AND t.account_id = :account_id"
        params["account_id"] = account_filter

    sql += " ORDER BY t.txn_time DESC FETCH FIRST 100 ROWS ONLY"

    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute(sql, params)
        data = rows_to_dict(cur)

    return jsonify(data)

# ── Insert a new transaction (triggers fire in Oracle) ─────────────
@app.route("/api/transactions", methods=["POST"])
def add_transaction():
    body = request.json
    required = ["account_id", "txn_type", "amount", "merchant", "location_city", "channel"]
    if not all(k in body for k in required):
        return jsonify({"error": "Missing fields", "required": required}), 400

    try:
        with get_conn() as conn:
            cur = conn.cursor()
            cur.execute("""
                INSERT INTO transactions
                    (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
                VALUES
                    (seq_txn_id.NEXTVAL, :account_id, :txn_type, :amount,
                     :merchant, :location_city, :channel)
                RETURNING txn_id INTO :txn_id
            """, {
                "account_id":    body["account_id"],
                "txn_type":      body["txn_type"].upper(),
                "amount":        float(body["amount"]),
                "merchant":      body["merchant"],
                "location_city": body["location_city"],
                "channel":       body["channel"].upper(),
                "txn_id":        cur.var(cx_Oracle.NUMBER)
            })

            # Get the new txn_id back from RETURNING clause
            new_txn_id = int(cur.bindvars["txn_id"].getvalue())
            conn.commit()

            # Fetch the result (triggers may have changed status)
            cur.execute("""
                SELECT t.txn_id, t.status, a.alert_type, a.risk_score, a.description
                FROM transactions t
                LEFT JOIN fraud_alerts a ON t.txn_id = a.txn_id
                WHERE t.txn_id = :txn_id
            """, {"txn_id": new_txn_id})
            result = rows_to_dict(cur)

        return jsonify({"success": True, "txn_id": new_txn_id, "result": result}), 201

    except cx_Oracle.DatabaseError as e:
        error_msg = str(e)
        if "ORA-20001" in error_msg:
            return jsonify({"error": "Account is FROZEN. Transaction rejected."}), 403
        return jsonify({"error": error_msg}), 500

# ── All fraud alerts ───────────────────────────────────────────────
@app.route("/api/alerts")
def alerts():
    resolved = request.args.get("resolved", "N")
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT a.alert_id, a.txn_id, a.account_id, c.full_name,
                   a.alert_type, a.risk_score, a.description,
                   a.resolved,
                   TO_CHAR(a.raised_at,'YYYY-MM-DD HH24:MI:SS') as raised_at
            FROM fraud_alerts a
            JOIN accounts acc ON a.account_id = acc.account_id
            JOIN customers c ON acc.customer_id = c.customer_id
            WHERE a.resolved = :resolved
            ORDER BY a.risk_score DESC, a.raised_at DESC
        """, {"resolved": resolved.upper()})
        data = rows_to_dict(cur)
    return jsonify(data)

# ── Resolve an alert ───────────────────────────────────────────────
@app.route("/api/alerts/<int:alert_id>/resolve", methods=["POST"])
def resolve_alert(alert_id):
    notes = request.json.get("notes", "Resolved by analyst") if request.json else "Resolved by analyst"
    with get_conn() as conn:
        cur = conn.cursor()
        cur.callproc("resolve_alert", [alert_id, notes])
        conn.commit()
    return jsonify({"success": True, "alert_id": alert_id})

# ── Accounts list ──────────────────────────────────────────────────
@app.route("/api/accounts")
def accounts():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT a.account_id, c.full_name, a.account_type,
                   a.balance, a.status,
                   (SELECT COUNT(*) FROM fraud_alerts f
                    WHERE f.account_id = a.account_id AND f.resolved='N') as open_alerts
            FROM accounts a
            JOIN customers c ON a.customer_id = c.customer_id
            ORDER BY a.account_id
        """)
        data = rows_to_dict(cur)
    return jsonify(data)

# ── Run batch audit ────────────────────────────────────────────────
@app.route("/api/batch-audit", methods=["POST"])
def batch_audit():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.callproc("batch_risk_audit")
        conn.commit()
    return jsonify({"success": True, "message": "Batch audit complete."})

# ── Audit log ─────────────────────────────────────────────────────
@app.route("/api/logs")
def logs():
    with get_conn() as conn:
        cur = conn.cursor()
        cur.execute("""
            SELECT log_id, txn_id, account_id, event_type,
                   old_status, new_status,
                   TO_CHAR(logged_at,'YYYY-MM-DD HH24:MI:SS') as logged_at,
                   notes
            FROM transaction_logs
            ORDER BY logged_at DESC
            FETCH FIRST 200 ROWS ONLY
        """)
        data = rows_to_dict(cur)
    return jsonify(data)

# ── Serve the SPA ─────────────────────────────────────────────────
@app.route("/")
def index():
    return render_template("index.html")

if __name__ == "__main__":
    app.run(debug=True, port=5000)
