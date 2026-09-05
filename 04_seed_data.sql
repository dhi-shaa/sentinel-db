-- ============================================================
-- FRAUD DETECTION ENGINE
-- File: 04_seed_data.sql
-- ============================================================

-- ============================================================
-- Customers & Accounts
-- (These were missing — every INSERT below joins against them
-- by email, so without this block the transaction inserts
-- silently match zero rows.)
-- ============================================================
INSERT INTO customers (customer_id, full_name, email, phone, city)
VALUES (seq_customer_id.NEXTVAL, 'Dhishaa', 'dhishaa@example.com', '9000000001', 'Coimbatore');
INSERT INTO customers (customer_id, full_name, email, phone, city)
VALUES (seq_customer_id.NEXTVAL, 'Miruthika', 'miruthika@example.com', '9000000002', 'Coimbatore');
INSERT INTO customers (customer_id, full_name, email, phone, city)
VALUES (seq_customer_id.NEXTVAL, 'Advaith', 'advaith@example.com', '9000000003', 'Bangalore');
INSERT INTO customers (customer_id, full_name, email, phone, city)
VALUES (seq_customer_id.NEXTVAL, 'Priya', 'priya@example.com', '9000000004', 'Mumbai');
COMMIT;

-- Account IDs come from seq_account_id, which starts at 5001 — so
-- Dhishaa's account below becomes 5001, matching the hardcoded
-- account ID in the RAPID-FIRE / HIGH-AMOUNT preset buttons in
-- index.html. Keep this order if you want those buttons to work
-- out of the box.
INSERT INTO accounts (account_id, customer_id, account_type, balance, status)
SELECT seq_account_id.NEXTVAL, customer_id, 'SAVINGS', 50000, 'ACTIVE'
FROM customers WHERE email = 'dhishaa@example.com';
INSERT INTO accounts (account_id, customer_id, account_type, balance, status)
SELECT seq_account_id.NEXTVAL, customer_id, 'SAVINGS', 50000, 'ACTIVE'
FROM customers WHERE email = 'miruthika@example.com';
INSERT INTO accounts (account_id, customer_id, account_type, balance, status)
SELECT seq_account_id.NEXTVAL, customer_id, 'SAVINGS', 20000, 'ACTIVE'
FROM customers WHERE email = 'advaith@example.com';
INSERT INTO accounts (account_id, customer_id, account_type, balance, status)
SELECT seq_account_id.NEXTVAL, customer_id, 'SAVINGS', 30000, 'ACTIVE'
FROM customers WHERE email = 'priya@example.com';
COMMIT;

-- Check what's in the DB before inserting transactions
SELECT customer_id, full_name, city FROM customers ORDER BY customer_id;
SELECT account_id, customer_id, account_type, status FROM accounts ORDER BY account_id;

-- ============================================================
-- Transactions — look up account_id dynamically by email
-- ============================================================

-- Normal transactions (should get APPROVED)
INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'DEBIT', 500, 'Swiggy', 'Coimbatore', 'MOBILE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'dhishaa@example.com';

INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'CREDIT', 10000, 'Salary', 'Coimbatore', 'ONLINE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'dhishaa@example.com';

INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'DEBIT', 2000, 'Amazon', 'Chennai', 'ONLINE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'miruthika@example.com';

COMMIT;

-- ============================================================
-- Suspicious scenario 1: RAPID-FIRE on Advaith's account
-- ============================================================
INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'DEBIT', 3000, 'Flipkart', 'Bangalore', 'ONLINE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'advaith@example.com';

INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'DEBIT', 4500, 'Myntra', 'Bangalore', 'ONLINE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'advaith@example.com';

INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'DEBIT', 2200, 'Nykaa', 'Bangalore', 'ONLINE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'advaith@example.com';

COMMIT;

-- ============================================================
-- Suspicious scenario 2: HIGH AMOUNT on Priya's account
-- ============================================================
INSERT INTO transactions (txn_id, account_id, txn_type, amount, merchant, location_city, channel)
SELECT seq_txn_id.NEXTVAL, a.account_id, 'DEBIT', 120000, 'Unknown Merchant', 'Mumbai', 'ONLINE'
FROM accounts a JOIN customers c ON a.customer_id = c.customer_id
WHERE c.email = 'priya@example.com';

COMMIT;

-- ============================================================
-- Verify final results
-- ============================================================
SELECT t.txn_id, t.account_id, c.full_name, t.amount, t.status,
       a.alert_type, a.risk_score
FROM transactions t
JOIN accounts acc ON t.account_id = acc.account_id
JOIN customers c   ON acc.customer_id = c.customer_id
LEFT JOIN fraud_alerts a ON t.txn_id = a.txn_id
ORDER BY t.txn_id;
