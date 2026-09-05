-- ============================================================
-- FRAUD DETECTION ENGINE
-- File: 03_triggers.sql
-- All triggers: real-time fraud detection + audit logging
-- ============================================================

-- ============================================================
-- TRIGGER 1: trg_txn_fraud_check
-- Fires AFTER INSERT on transactions.
-- Scores the new transaction and raises alerts automatically.
-- This is the heart of the real-time detection engine.
-- ============================================================
CREATE OR REPLACE TRIGGER trg_txn_fraud_check
AFTER INSERT ON transactions
FOR EACH ROW
DECLARE
    v_score         NUMBER;
    v_alert_type    VARCHAR2(50);
    v_desc          VARCHAR2(500);

    -- For rapid-fire sub-check
    v_rapid_count   NUMBER;
    v_rapid_min     NUMBER;
    v_rapid_limit   NUMBER;

    -- For geo-velocity sub-check
    v_last_city     VARCHAR2(50);
    v_last_time     TIMESTAMP;

    -- For high-amount sub-check
    v_high_thresh   NUMBER;
BEGIN
    -- Only check DEBIT and TRANSFER — CREDITs are low risk
    IF :NEW.txn_type NOT IN ('DEBIT','TRANSFER') THEN
        RETURN;
    END IF;

    -- Compute composite risk score
    v_score := compute_risk_score(
        :NEW.txn_id,
        :NEW.account_id,
        :NEW.amount,
        :NEW.location_city,
        :NEW.txn_time
    );

    -- Only raise alert if risk score warrants it
    IF v_score >= 40 THEN

        -- Determine primary alert type (most severe signal wins the label)
        v_rapid_limit := get_rule_threshold('RAPID_FIRE_COUNT');
        v_rapid_min   := get_rule_threshold('RAPID_FIRE_MINUTES');

        SELECT COUNT(*) INTO v_rapid_count
        FROM transactions
        WHERE account_id = :NEW.account_id
          AND txn_id    != :NEW.txn_id
          AND txn_time  >= :NEW.txn_time - (v_rapid_min / 1440);

        v_high_thresh := get_rule_threshold('HIGH_AMOUNT');

        IF v_rapid_count >= v_rapid_limit THEN
            v_alert_type := 'RAPID_FIRE';
            v_desc := v_rapid_count || ' transactions in ' || v_rapid_min || ' minutes. ';
        ELSIF :NEW.amount > v_high_thresh THEN
            v_alert_type := 'HIGH_AMOUNT';
            v_desc := 'Single transaction of ' || :NEW.amount || ' exceeds threshold. ';
        ELSE
            -- Check geo-velocity
            BEGIN
                SELECT location_city, txn_time
                INTO v_last_city, v_last_time
                FROM (
                    SELECT location_city, txn_time FROM transactions
                    WHERE account_id = :NEW.account_id
                      AND txn_id    != :NEW.txn_id
                    ORDER BY txn_time DESC
                ) WHERE ROWNUM = 1;

                IF v_last_city IS NOT NULL
                   AND :NEW.location_city IS NOT NULL
                   AND v_last_city != :NEW.location_city
                   AND (:NEW.txn_time - v_last_time) < (30/1440)
                THEN
                    v_alert_type := 'GEO_VELOCITY';
                    v_desc := 'Location jumped from ' || v_last_city || ' to ' || :NEW.location_city || ' within 30 minutes. ';
                ELSE
                    v_alert_type := 'COMPOSITE_RISK';
                    v_desc := 'Multiple moderate signals detected. ';
                END IF;
            EXCEPTION
                WHEN NO_DATA_FOUND THEN
                    v_alert_type := 'COMPOSITE_RISK';
                    v_desc := 'Risk signals detected on new account. ';
            END;
        END IF;

        v_desc := v_desc || 'Risk Score: ' || v_score || '/100.';

        -- Raise the alert (procedure handles status update)
        raise_fraud_alert(
            :NEW.txn_id, :NEW.account_id,
            v_alert_type, v_score, v_desc
        );
    ELSE
        -- Safe transaction: approve immediately
        UPDATE transactions SET status = 'APPROVED' WHERE txn_id = :NEW.txn_id;
    END IF;

EXCEPTION
    WHEN OTHERS THEN
        -- Never let fraud check crash the transaction insert
        -- Log the error and continue
        INSERT INTO transaction_logs (log_id, txn_id, account_id, event_type, notes)
        VALUES (seq_log_id.NEXTVAL, :NEW.txn_id, :NEW.account_id,
                'TRIGGER_ERROR', SQLERRM);
        COMMIT;
END;
/

-- ============================================================
-- TRIGGER 2: trg_txn_audit_log
-- Fires AFTER INSERT OR UPDATE on transactions.
-- Writes an immutable audit trail to transaction_logs.
-- ============================================================
CREATE OR REPLACE TRIGGER trg_txn_audit_log
AFTER INSERT OR UPDATE OF status ON transactions
FOR EACH ROW
DECLARE
    v_event VARCHAR2(30);
BEGIN
    IF INSERTING THEN
        v_event := 'TXN_INSERTED';
    ELSIF UPDATING THEN
        v_event := 'STATUS_CHANGED';
    END IF;

    INSERT INTO transaction_logs (
        log_id, txn_id, account_id, event_type,
        old_status, new_status, notes
    ) VALUES (
        seq_log_id.NEXTVAL,
        :NEW.txn_id,
        :NEW.account_id,
        v_event,
        :OLD.status,
        :NEW.status,
        'Channel: ' || :NEW.channel || ' | Amount: ' || :NEW.amount
    );
END;
/

-- ============================================================
-- TRIGGER 3: trg_freeze_blocked_account
-- If a single account accumulates 3+ unresolved BLOCKED alerts,
-- automatically freeze the account.
-- ============================================================
CREATE OR REPLACE TRIGGER trg_freeze_blocked_account
AFTER INSERT ON fraud_alerts
FOR EACH ROW
DECLARE
    v_block_count   NUMBER;
BEGIN
    SELECT COUNT(*) INTO v_block_count
    FROM fraud_alerts
    WHERE account_id = :NEW.account_id
      AND resolved   = 'N'
      AND risk_score >= 70;

    IF v_block_count >= 3 THEN
        UPDATE accounts
        SET status = 'FROZEN'
        WHERE account_id = :NEW.account_id;

        INSERT INTO transaction_logs (
            log_id, txn_id, account_id, event_type, notes
        ) VALUES (
            seq_log_id.NEXTVAL, :NEW.txn_id, :NEW.account_id,
            'ACCOUNT_FROZEN',
            'Auto-frozen after ' || v_block_count || ' high-risk unresolved alerts.'
        );
        COMMIT;
    END IF;
END;
/

-- ============================================================
-- TRIGGER 4: trg_prevent_frozen_txn
-- BEFORE INSERT — blocks any new transaction on a FROZEN account.
-- ============================================================
CREATE OR REPLACE TRIGGER trg_prevent_frozen_txn
BEFORE INSERT ON transactions
FOR EACH ROW
DECLARE
    v_status VARCHAR2(10);
BEGIN
    SELECT status INTO v_status
    FROM accounts
    WHERE account_id = :NEW.account_id;

    IF v_status = 'FROZEN' THEN
        RAISE_APPLICATION_ERROR(-20001,
            'Account ' || :NEW.account_id || ' is FROZEN. Transaction rejected.');
    END IF;
EXCEPTION
    WHEN NO_DATA_FOUND THEN
        RAISE_APPLICATION_ERROR(-20002, 'Account not found.');
END;
/
