# SentinelDB — Fraud Detection Engine

Oracle PL/SQL-based fraud detection system with real-time transaction risk scoring, automated alerting, and account freezing — served through a Flask REST API and a vanilla-JS dashboard.

---

## Overview

SentinelDB evaluates every incoming transaction against a set of configurable risk rules (rapid-fire frequency, high transaction amounts, 24-hour velocity, geo-location anomalies, and odd-hour activity), producing a 0–100 risk score. Transactions above defined thresholds are automatically flagged or blocked, and accounts with repeated high-risk activity are frozen without manual intervention.

---

## Project Structure

```
fraud_detection/
├── sql/
│   ├── 01_schema.sql       ← Tables, sequences, and rule configuration
│   ├── 02_plsql_logic.sql  ← Functions and procedures (risk scoring engine)
│   ├── 03_triggers.sql     ← Real-time detection triggers
│   └── 04_seed_data.sql    ← Sample data and test scenarios
├── backend/
│   └── app.py              ← Flask REST API
└── frontend/
    └── templates/
        └── index.html      ← Dashboard UI
```

---

## Core Components

| Component | Type | Purpose |
|---|---|---|
| `compute_risk_score` | Function | Returns a 0–100 risk score for a transaction |
| `raise_fraud_alert` | Procedure | Inserts an alert and updates transaction status |
| `resolve_alert` | Procedure | Marks an alert as resolved and restores transaction status |
| `batch_risk_audit` | Procedure (cursor-driven) | Re-scores pending transactions in bulk |
| `generate_account_report` | Procedure (cursor-driven) | Produces a per-account transaction summary |
| `trg_txn_fraud_check` | Trigger (AFTER INSERT) | Scores each new debit/transfer in real time |
| `trg_txn_audit_log` | Trigger (AFTER INSERT/UPDATE) | Maintains an immutable audit trail |
| `trg_freeze_blocked_account` | Trigger (AFTER INSERT) | Automatically freezes accounts after repeated high-risk alerts |
| `trg_prevent_frozen_txn` | Trigger (BEFORE INSERT) | Blocks new transactions on frozen accounts |
| `RISK_RULES` table | Configuration | Stores risk thresholds so none are hardcoded in application logic |

---

## Setup

### 1. Database
Run the SQL files in order using SQL*Plus or SQL Developer:
```sql
@01_schema.sql
@02_plsql_logic.sql
@03_triggers.sql
@04_seed_data.sql
```

### 2. Backend
```bash
pip install flask oracledb flask-cors

export ORACLE_USER=your_username
export ORACLE_PASS=your_password
export ORACLE_DSN=localhost:1521/XE

cd backend
python app.py
# Runs on http://localhost:5000
```

### 3. Frontend
Open `frontend/templates/index.html` directly, or visit `http://localhost:5000`, since Flask serves it.

---

## Test Scenarios

| Scenario | How to trigger it |
|---|---|
| Rapid-fire | Insert 3+ debit transactions on the same account within 2 minutes, or use the RAPID-FIRE preset in the Simulate tab |
| High amount | Submit a debit above ₹50,000, or use the HIGH-AMOUNT preset |
| Geo-velocity | Submit a debit from one city, then another from a different city on the same account within 30 minutes |
| Account auto-freeze | Accumulate 3 unresolved high-risk (score ≥ 70) alerts on one account |
| Frozen account block | Attempt a transaction on a frozen account — it is rejected with an ORA-20001 error |
| Batch audit | Run the batch audit endpoint or button to re-score all pending transactions via a cursor-driven procedure |

---

## API Endpoints

| Method | Endpoint | Description |
|---|---|---|
| GET | `/api/health` | Database connectivity check |
| GET | `/api/dashboard` | Summary metrics and trends |
| GET | `/api/transactions?status=FLAGGED` | Filtered transaction list |
| POST | `/api/transactions` | Insert a new transaction (triggers real-time scoring) |
| GET | `/api/alerts?resolved=N` | Open fraud alerts |
| POST | `/api/alerts/:id/resolve` | Resolve an alert |
| GET | `/api/accounts` | All accounts with open alert counts |
| POST | `/api/batch-audit` | Run the batch risk audit |
| GET | `/api/logs` | Audit log (most recent 200 entries) |
