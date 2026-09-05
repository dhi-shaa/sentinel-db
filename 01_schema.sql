-- ============================================================
-- FRAUD DETECTION ENGINE
-- File: 01_schema.sql
-- Run this first to create all tables and sequences
-- ============================================================

-- Drop existing objects (safe re-run)
BEGIN
    FOR t IN (SELECT table_name FROM user_tables WHERE table_name IN (
        'CUSTOMERS','ACCOUNTS','TRANSACTIONS','FRAUD_ALERTS',
        'TRANSACTION_LOGS','RISK_RULES','LOCATIONS'
    )) LOOP
        EXECUTE IMMEDIATE 'DROP TABLE ' || t.table_name || ' CASCADE CONSTRAINTS';
    END LOOP;
END;
/

-- Sequences
CREATE SEQUENCE seq_customer_id START WITH 1001 INCREMENT BY 1;
CREATE SEQUENCE seq_account_id  START WITH 5001 INCREMENT BY 1;
CREATE SEQUENCE seq_txn_id      START WITH 9001 INCREMENT BY 1;
CREATE SEQUENCE seq_alert_id    START WITH 1    INCREMENT BY 1;
CREATE SEQUENCE seq_log_id      START WITH 1    INCREMENT BY 1;

-- ============================================================
-- CUSTOMERS
-- ============================================================
CREATE TABLE customers (
    customer_id     NUMBER PRIMARY KEY,
    full_name       VARCHAR2(100) NOT NULL,
    email           VARCHAR2(150) UNIQUE NOT NULL,
    phone           VARCHAR2(15),
    city            VARCHAR2(50),
    created_at      DATE DEFAULT SYSDATE
);

-- ============================================================
-- ACCOUNTS
-- ============================================================
CREATE TABLE accounts (
    account_id      NUMBER PRIMARY KEY,
    customer_id     NUMBER NOT NULL,
    account_type    VARCHAR2(20) DEFAULT 'SAVINGS'
                        CHECK (account_type IN ('SAVINGS','CURRENT','WALLET')),
    balance         NUMBER(15,2) DEFAULT 0,
    status          VARCHAR2(10) DEFAULT 'ACTIVE'
                        CHECK (status IN ('ACTIVE','FROZEN','CLOSED')),
    created_at      DATE DEFAULT SYSDATE,
    CONSTRAINT fk_acc_cust FOREIGN KEY (customer_id) REFERENCES customers(customer_id)
);

-- ============================================================
-- LOCATIONS (for geo-velocity checks)
-- ============================================================
CREATE TABLE locations (
    location_id     NUMBER PRIMARY KEY,
    city            VARCHAR2(50),
    country         VARCHAR2(50),
    latitude        NUMBER(9,6),
    longitude       NUMBER(9,6)
);

-- ============================================================
-- TRANSACTIONS  (core fact table)
-- ============================================================
CREATE TABLE transactions (
    txn_id          NUMBER PRIMARY KEY,
    account_id      NUMBER NOT NULL,
    txn_type        VARCHAR2(20) NOT NULL
                        CHECK (txn_type IN ('DEBIT','CREDIT','TRANSFER')),
    amount          NUMBER(15,2) NOT NULL,
    merchant        VARCHAR2(100),
    location_city   VARCHAR2(50),
    txn_time        TIMESTAMP DEFAULT SYSTIMESTAMP,
    status          VARCHAR2(15) DEFAULT 'PENDING'
                        CHECK (status IN ('PENDING','APPROVED','FLAGGED','BLOCKED')),
    channel         VARCHAR2(20) DEFAULT 'ONLINE'
                        CHECK (channel IN ('ONLINE','ATM','POS','MOBILE')),
    CONSTRAINT fk_txn_acc FOREIGN KEY (account_id) REFERENCES accounts(account_id)
);

-- ============================================================
-- FRAUD_ALERTS  (raised by triggers / procedures)
-- ============================================================
CREATE TABLE fraud_alerts (
    alert_id        NUMBER PRIMARY KEY,
    txn_id          NUMBER NOT NULL,
    account_id      NUMBER NOT NULL,
    alert_type      VARCHAR2(50) NOT NULL,   -- e.g. 'RAPID_FIRE','GEO_VELOCITY'
    risk_score      NUMBER(5,2),             -- 0–100
    description     VARCHAR2(500),
    resolved        CHAR(1) DEFAULT 'N' CHECK (resolved IN ('Y','N')),
    raised_at       TIMESTAMP DEFAULT SYSTIMESTAMP,
    resolved_at     TIMESTAMP,
    CONSTRAINT fk_alert_txn FOREIGN KEY (txn_id) REFERENCES transactions(txn_id)
);

-- ============================================================
-- TRANSACTION_LOGS  (immutable audit trail, written by trigger)
-- ============================================================
CREATE TABLE transaction_logs (
    log_id          NUMBER PRIMARY KEY,
    txn_id          NUMBER,
    account_id      NUMBER,
    event_type      VARCHAR2(30),   -- INSERT / STATUS_CHANGE / FLAGGED
    old_status      VARCHAR2(15),
    new_status      VARCHAR2(15),
    logged_at       TIMESTAMP DEFAULT SYSTIMESTAMP,
    notes           VARCHAR2(500)
);

-- ============================================================
-- RISK_RULES  (configurable thresholds — no hard-coding)
-- ============================================================
CREATE TABLE risk_rules (
    rule_name       VARCHAR2(50) PRIMARY KEY,
    threshold_value NUMBER,
    description     VARCHAR2(200),
    is_active       CHAR(1) DEFAULT 'Y' CHECK (is_active IN ('Y','N'))
);

-- Seed default rules
INSERT INTO risk_rules VALUES ('RAPID_FIRE_COUNT',    3,     'Max transactions allowed within rapid-fire window', 'Y');
INSERT INTO risk_rules VALUES ('RAPID_FIRE_MINUTES',  2,     'Minutes window for rapid-fire check', 'Y');
INSERT INTO risk_rules VALUES ('HIGH_AMOUNT',         50000, 'Single transaction amount threshold (INR)', 'Y');
INSERT INTO risk_rules VALUES ('VELOCITY_AMOUNT',     100000,'Total debit in 24h threshold (INR)', 'Y');
INSERT INTO risk_rules VALUES ('ODD_HOUR_START',      1,     'Odd-hours window start (1 AM)', 'Y');
INSERT INTO risk_rules VALUES ('ODD_HOUR_END',        4,     'Odd-hours window end (4 AM)', 'Y');

COMMIT;
