# SentinelDB — Fraud Detection Engine
### DBMS End-Sem Project | Oracle PL/SQL + Flask + Vanilla JS

---

## Project Structure

```
fraud_detection/
├── sql/
│   ├── 01_schema.sql       ← Tables, sequences, seed rules
│   ├── 02_plsql_logic.sql  ← Functions, procedures (risk engine)
│   ├── 03_triggers.sql     ← 4 triggers (real-time detection)
│   └── 04_seed_data.sql    ← Sample data + test scenarios
├── backend/
│   └── app.py              ← Flask REST API (cx_Oracle)
└── frontend/
    └── templates/
        └── index.html      ← Single-page dashboard UI
```

---

## What Uses What (for your viva)

| Component | Oracle Feature | Purpose |
|---|---|---|
| `compute_risk_score` | **Function** | Returns 0–100 score for a transaction |
| `raise_fraud_alert` | **Procedure** | Inserts alert + updates txn status |
| `resolve_alert` | **Procedure** | Analyst clears an alert |
| `batch_risk_audit` | **Procedure + Cursor** | Iterates PENDING txns, scores each |
| `generate_account_report` | **Procedure + Cursor** | DBMS_OUTPUT report |
| `trg_txn_fraud_check` | **AFTER INSERT Trigger** | Real-time scoring on every debit |
| `trg_txn_audit_log` | **AFTER INSERT/UPDATE Trigger** | Immutable audit trail |
| `trg_freeze_blocked_account` | **AFTER INSERT Trigger** | Auto-freezes accounts |
| `trg_prevent_frozen_txn` | **BEFORE INSERT Trigger** | Hard block on frozen accounts |
| `RISK_RULES` table | Configurable thresholds | No magic numbers in code |

---

## Setup Instructions

### Step 1 — Oracle DB
Run SQL files in order in SQL*Plus or SQL Developer:
```
@01_schema.sql
@02_plsql_logic.sql
@03_triggers.sql
@04_seed_data.sql
```

### Step 2 — Python Backend
```bash
pip install flask cx_Oracle flask-cors

# Set your Oracle credentials
export ORACLE_USER=your_username
export ORACLE_PASS=your_password
export ORACLE_DSN=localhost:1521/XE

cd backend
python app.py
# Runs on http://localhost:5000
```

### Step 3 — Open the UI
Open `frontend/templates/index.html` in your browser
**or** visit `http://localhost:5000` (Flask serves it).

---

## Test Scenarios

### 1. Rapid-fire (triggers RAPID_FIRE alert)
Insert 3+ DEBIT transactions on the same account within 2 minutes.
Use the **⚡ RAPID-FIRE PRESET** button in the Simulate tab.

### 2. High amount (triggers HIGH_AMOUNT alert)
Submit a DEBIT > ₹50,000. Use the **💸 HIGH-AMOUNT PRESET**.

### 3. Geo-velocity
Submit a DEBIT from Chennai, then immediately one from Mumbai
on the same account. Within 30 min → GEO_VELOCITY alert.

### 4. Account auto-freeze
Accumulate 3 BLOCKED (risk ≥ 70) unresolved alerts on one account.
`trg_freeze_blocked_account` fires and freezes it automatically.

### 5. Frozen account block
After an account is FROZEN, try inserting a transaction.
`trg_prevent_frozen_txn` raises ORA-20001 and rejects it.

### 6. Batch audit
Hit **▶ RUN BATCH AUDIT** — calls `batch_risk_audit` procedure,
which uses a cursor to iterate all PENDING transactions and score them.

---

## API Endpoints

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/health` | DB connectivity check |
| GET | `/api/dashboard` | KPIs + breakdown + trend |
| GET | `/api/transactions?status=FLAGGED` | Filtered transactions |
| POST | `/api/transactions` | Insert new transaction (triggers fire) |
| GET | `/api/alerts?resolved=N` | Open fraud alerts |
| POST | `/api/alerts/:id/resolve` | Resolve an alert |
| GET | `/api/accounts` | All accounts with alert count |
| POST | `/api/batch-audit` | Run batch_risk_audit procedure |
| GET | `/api/logs` | Audit log (last 200 entries) |
