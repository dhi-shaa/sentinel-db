-- ============================================================
-- FRAUD DETECTION ENGINE
-- File: 02_plsql_logic.sql
-- Core functions, procedures, and the risk scoring engine
-- ============================================================

-- ============================================================
-- FUNCTION: get_rule_threshold
-- Reads a rule value from RISK_RULES table
-- ============================================================
CREATE OR REPLACE FUNCTION get_rule_threshold(p_rule_name VARCHAR2)
RETURN NUMBER IS
    v_val NUMBER;
BEGIN
    SELECT threshold_value INTO v_val
    FROM risk_rules
    WHERE rule_name = p_rule_name AND is_active = 'Y';
    RETURN v_val;
EXCEPTION
    WHEN NO_DATA_FOUND THEN RETURN NULL;
END;
/

-- ============================================================
-- FUNCTION: compute_risk_score
-- Returns a 0-100 risk score for a given transaction
-- based on multiple independent signals
-- ============================================================
CREATE OR REPLACE FUNCTION compute_risk_score(
    p_txn_id        NUMBER,
    p_account_id    NUMBER,
    p_amount        NUMBER,
    p_location_city VARCHAR2,
    p_txn_time      TIMESTAMP
) RETURN NUMBER IS
    v_score             NUMBER := 0;

    -- Rapid-fire check
    v_rapid_count       NUMBER;
    v_rapid_minutes     NUMBER;
    v_rapid_limit       NUMBER;

    -- Velocity check (24h total)
    v_velocity_total    NUMBER;
    v_velocity_limit    NUMBER;

    -- High amount check
    v_high_threshold    NUMBER;

    -- Geo-velocity: last transaction city
    v_last_city         VARCHAR2(50);
    v_last_time         TIMESTAMP;

    -- Odd-hours
    v_hour              NUMBER;
    v_odd_start         NUMBER;
    v_odd_end           NUMBER;

BEGIN
    -- ---- 1. RAPID-FIRE CHECK (up to +35 points) ----
    v_rapid_limit   := get_rule_threshold('RAPID_FIRE_COUNT');
    v_rapid_minutes := get_rule_threshold('RAPID_FIRE_MINUTES');

    SELECT COUNT(*) INTO v_rapid_count
    FROM transactions
    WHERE account_id = p_account_id
      AND txn_id    != p_txn_id
      AND txn_time  >= p_txn_time - (v_rapid_minutes / 1440);

    IF v_rapid_count >= v_rapid_limit THEN
        v_score := v_score + 35;
    ELSIF v_rapid_count = v_rapid_limit - 1 THEN
        v_score := v_score + 15;
    END IF;

    -- ---- 2. HIGH SINGLE AMOUNT CHECK (up to +25 points) ----
    v_high_threshold := get_rule_threshold('HIGH_AMOUNT');
    IF p_amount > v_high_threshold * 2 THEN
        v_score := v_score + 25;
    ELSIF p_amount > v_high_threshold THEN
        v_score := v_score + 12;
    END IF;

    -- ---- 3. 24-HOUR VELOCITY CHECK (up to +25 points) ----
    v_velocity_limit := get_rule_threshold('VELOCITY_AMOUNT');

    SELECT NVL(SUM(amount), 0) INTO v_velocity_total
    FROM transactions
    WHERE account_id = p_account_id
      AND txn_type   = 'DEBIT'
      AND txn_id    != p_txn_id
      AND txn_time  >= p_txn_time - 1;  -- last 24 hours

    IF (v_velocity_total + p_amount) > v_velocity_limit * 1.5 THEN
        v_score := v_score + 25;
    ELSIF (v_velocity_total + p_amount) > v_velocity_limit THEN
        v_score := v_score + 12;
    END IF;

    -- ---- 4. GEO-VELOCITY CHECK (up to +20 points) ----
    -- Flag if location changed since last transaction within 30 min
    BEGIN
        SELECT location_city, txn_time
        INTO v_last_city, v_last_time
        FROM (
            SELECT location_city, txn_time
            FROM transactions
            WHERE account_id = p_account_id
              AND txn_id    != p_txn_id
            ORDER BY txn_time DESC
        )
        WHERE ROWNUM = 1;

        IF v_last_city IS NOT NULL AND p_location_city IS NOT NULL
           AND v_last_city != p_location_city
           AND (p_txn_time - v_last_time) < (30/1440) THEN  -- within 30 min
            v_score := v_score + 20;
        END IF;
    EXCEPTION
        WHEN NO_DATA_FOUND THEN NULL;  -- first transaction, no geo check
    END;

    -- ---- 5. ODD HOURS CHECK (up to +10 points) ----
    v_odd_start := get_rule_threshold('ODD_HOUR_START');
    v_odd_end   := get_rule_threshold('ODD_HOUR_END');
    v_hour      := TO_NUMBER(TO_CHAR(CAST(p_txn_time AS DATE), 'HH24'));

    IF v_hour >= v_odd_start AND v_hour <= v_odd_end THEN
        v_score := v_score + 10;
    END IF;

    -- Cap at 100
    RETURN LEAST(v_score, 100);
END;
/

-- ============================================================
-- PROCEDURE: raise_fraud_alert
-- Inserts a fraud alert and updates transaction status
-- ============================================================
CREATE OR REPLACE PROCEDURE raise_fraud_alert(
    p_txn_id        NUMBER,
    p_account_id    NUMBER,
    p_alert_type    VARCHAR2,
    p_risk_score    NUMBER,
    p_description   VARCHAR2
) IS
BEGIN
    INSERT INTO fraud_alerts (
        alert_id, txn_id, account_id, alert_type, risk_score, description
    ) VALUES (
        seq_alert_id.NEXTVAL, p_txn_id, p_account_id,
        p_alert_type, p_risk_score, p_description
    );

    -- High risk: BLOCK the transaction; medium: FLAG it
    IF p_risk_score >= 70 THEN
        UPDATE transactions SET status = 'BLOCKED' WHERE txn_id = p_txn_id;
    ELSE
        UPDATE transactions SET status = 'FLAGGED' WHERE txn_id = p_txn_id;
    END IF;

    -- REMOVED COMMIT - let the calling transaction handle it
END;
/

-- ============================================================
-- PROCEDURE: resolve_alert
-- Analyst marks an alert as resolved (false positive or confirmed)
-- ============================================================
CREATE OR REPLACE PROCEDURE resolve_alert(
    p_alert_id  NUMBER,
    p_notes     VARCHAR2 DEFAULT NULL
) IS
    v_txn_id    NUMBER;
BEGIN
    SELECT txn_id INTO v_txn_id FROM fraud_alerts WHERE alert_id = p_alert_id;

    UPDATE fraud_alerts
    SET resolved    = 'Y',
        resolved_at = SYSTIMESTAMP
    WHERE alert_id  = p_alert_id;

    -- Unblock transaction if it was blocked by this alert
    UPDATE transactions
    SET status = 'APPROVED'
    WHERE txn_id = v_txn_id
      AND status IN ('BLOCKED', 'FLAGGED');

    -- Log the resolution
    INSERT INTO transaction_logs (log_id, txn_id, account_id, event_type, notes)
    SELECT seq_log_id.NEXTVAL, t.txn_id, t.account_id,
           'ALERT_RESOLVED', p_notes
    FROM transactions t
    WHERE t.txn_id = v_txn_id;

    -- No COMMIT here on purpose: app.py's /api/alerts/<id>/resolve route
    -- calls conn.commit() after callproc(), so the caller controls the
    -- transaction boundary. (Previously this procedure committed internally,
    -- which duplicated app.py's commit — fixed.)
END;
/

-- ============================================================
-- PROCEDURE: batch_risk_audit  (cursor-driven batch job)
-- Re-evaluates all PENDING transactions and scores them.
-- Meant to be run periodically (e.g., every hour via DBMS_SCHEDULER).
-- ============================================================
CREATE OR REPLACE PROCEDURE batch_risk_audit IS
    -- Only DEBIT/TRANSFER go through risk scoring, matching what
    -- trg_txn_fraud_check does in real time. CREDIT transactions
    -- (salary, refunds, etc.) are not risk-scored the same way —
    -- compute_risk_score's checks (high amount, 24h debit velocity)
    -- are written for outgoing money and would misfire on a large
    -- but legitimate incoming credit.
    CURSOR c_pending IS
        SELECT txn_id, account_id, amount, location_city, txn_time
        FROM   transactions
        WHERE  status   = 'PENDING'
          AND  txn_type IN ('DEBIT', 'TRANSFER');

    v_score     NUMBER;
    v_desc      VARCHAR2(500);
    v_processed NUMBER := 0;
    v_flagged   NUMBER := 0;
    v_credits   NUMBER := 0;
BEGIN
    -- Pending CREDITs are approved directly — nothing to risk-score.
    UPDATE transactions
    SET status = 'APPROVED'
    WHERE status = 'PENDING' AND txn_type = 'CREDIT';
    v_credits := SQL%ROWCOUNT;

    FOR rec IN c_pending LOOP
        v_score := compute_risk_score(
            rec.txn_id, rec.account_id, rec.amount,
            rec.location_city, rec.txn_time
        );

        IF v_score >= 40 THEN
            -- Build a human-readable description
            v_desc := 'Batch audit risk score: ' || v_score || '/100. ';
            IF v_score >= 70 THEN
                v_desc := v_desc || 'HIGH RISK — transaction blocked.';
            ELSE
                v_desc := v_desc || 'MODERATE RISK — transaction flagged for review.';
            END IF;

            raise_fraud_alert(
                rec.txn_id, rec.account_id,
                'BATCH_AUDIT', v_score, v_desc
            );
            v_flagged := v_flagged + 1;
        ELSE
            -- Clean transaction: approve it
            UPDATE transactions SET status = 'APPROVED' WHERE txn_id = rec.txn_id;
        END IF;

        v_processed := v_processed + 1;
    END LOOP;

    COMMIT;
    DBMS_OUTPUT.PUT_LINE('Batch audit complete. Processed: ' || v_processed ||
                          ', Flagged: ' || v_flagged ||
                          ', Credits auto-approved: ' || v_credits);
END;
/

-- ============================================================
-- PROCEDURE: generate_account_report
-- Cursor-driven summary report for an account
-- ============================================================
CREATE OR REPLACE PROCEDURE generate_account_report(p_account_id NUMBER) IS
    CURSOR c_txns IS
        SELECT txn_id, txn_type, amount, merchant, location_city, txn_time, status
        FROM   transactions
        WHERE  account_id = p_account_id
        ORDER BY txn_time DESC;

    v_total_debit   NUMBER := 0;
    v_total_credit  NUMBER := 0;
    v_alert_count   NUMBER := 0;
BEGIN
    DBMS_OUTPUT.PUT_LINE('=== Account Report: ' || p_account_id || ' ===');
    DBMS_OUTPUT.PUT_LINE(RPAD('TXN_ID',8) || RPAD('TYPE',10) || RPAD('AMOUNT',12) || RPAD('STATUS',10) || 'TIME');
    DBMS_OUTPUT.PUT_LINE(RPAD('-',60,'-'));

    FOR rec IN c_txns LOOP
        DBMS_OUTPUT.PUT_LINE(
            RPAD(rec.txn_id,8) || RPAD(rec.txn_type,10) ||
            RPAD(rec.amount,12) || RPAD(rec.status,10) ||
            TO_CHAR(rec.txn_time,'DD-MON HH24:MI')
        );
        IF rec.txn_type = 'DEBIT'  THEN v_total_debit  := v_total_debit  + rec.amount; END IF;
        IF rec.txn_type = 'CREDIT' THEN v_total_credit := v_total_credit + rec.amount; END IF;
    END LOOP;

    SELECT COUNT(*) INTO v_alert_count
    FROM fraud_alerts WHERE account_id = p_account_id AND resolved = 'N';

    DBMS_OUTPUT.PUT_LINE(RPAD('-',60,'-'));
    DBMS_OUTPUT.PUT_LINE('Total Debit : ' || v_total_debit);
    DBMS_OUTPUT.PUT_LINE('Total Credit: ' || v_total_credit);
    DBMS_OUTPUT.PUT_LINE('Open Alerts : ' || v_alert_count);
END;
/
