Clinic Appointment Scheduling
DROP SCHEMA IF EXISTS q4_clinic CASCADE;
CREATE SCHEMA q4_clinic;
SET search_path TO q4_clinic;

(a) Tables and data
CREATE TABLE patients (patient_id SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);
CREATE TABLE doctors  (doctor_id  SERIAL PRIMARY KEY, full_name VARCHAR(100) NOT NULL);

CREATE TABLE appointments (
    appointment_id  SERIAL PRIMARY KEY,
    patient_id      INT NOT NULL REFERENCES patients(patient_id),
    doctor_id       INT NOT NULL REFERENCES doctors(doctor_id),
    appointment_day DATE NOT NULL,
    slot_time       TIME NOT NULL CHECK (slot_time IN ('09:00','10:00','11:00','12:00')),
    status          VARCHAR(10) NOT NULL CHECK (status IN ('BOOKED','ATTENDED','CANCELLED'))
);

CREATE TABLE clinic_summary (
    summary_date    DATE PRIMARY KEY,
    booked_count    INT NOT NULL,
    attended_count  INT NOT NULL,
    cancelled_count INT NOT NULL
);

INSERT INTO patients (full_name) VALUES ('Alice'), ('Brian'), ('Grace');
INSERT INTO doctors  (full_name) VALUES ('Dr Mulenga'), ('Dr Chola'), ('Dr Banda');

INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status) VALUES
(1, 1, CURRENT_DATE,     '09:00', 'BOOKED'),
(2, 1, CURRENT_DATE,     '10:00', 'BOOKED'),
(3, 2, CURRENT_DATE,     '09:00', 'BOOKED'),
(1, 2, CURRENT_DATE - 1, '09:00', 'ATTENDED'),
(2, 3, CURRENT_DATE - 1, '11:00', 'CANCELLED'),
(3, 3, CURRENT_DATE - 1, '12:00', 'ATTENDED');

--(b) Function: doctor's non-cancelled appointments on a day
CREATE FUNCTION fn_daily_load(p_doctor_id INT, p_day DATE) RETURNS INT AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor';
    END IF;
    RETURN (SELECT COUNT(*) FROM appointments
            WHERE doctor_id = p_doctor_id
              AND appointment_day = p_day
              AND status <> 'CANCELLED')::INT;
END;
$$ LANGUAGE plpgsql;

SELECT fn_daily_load(1, CURRENT_DATE);   -- 2
SELECT fn_daily_load(3, CURRENT_DATE);   -- 0

(c) Procedure: book an appointment
CREATE PROCEDURE pr_book_appointment(p_patient_id INT, p_doctor_id INT, p_day DATE, p_slot TIME)
LANGUAGE plpgsql AS $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM patients WHERE patient_id = p_patient_id) THEN
        RAISE EXCEPTION 'Unknown patient';
    END IF;
    IF NOT EXISTS (SELECT 1 FROM doctors WHERE doctor_id = p_doctor_id) THEN
        RAISE EXCEPTION 'Unknown doctor';
    END IF;
    IF p_day < CURRENT_DATE THEN
        RAISE EXCEPTION 'Date is in the past';
    END IF;
    IF p_slot NOT IN ('09:00','10:00','11:00','12:00') THEN
        RAISE EXCEPTION 'Unsupported slot';
    END IF;
    INSERT INTO appointments (patient_id, doctor_id, appointment_day, slot_time, status)
    VALUES (p_patient_id, p_doctor_id, p_day, p_slot, 'BOOKED');
END;
$$;

-- (d) Trigger: stop two active appointments in the same slot
CREATE FUNCTION trg_clash_fn() RETURNS TRIGGER AS $$
BEGIN
    IF NEW.status <> 'CANCELLED' AND EXISTS (
        SELECT 1 FROM appointments
        WHERE doctor_id = NEW.doctor_id
          AND appointment_day = NEW.appointment_day
          AND slot_time = NEW.slot_time
          AND status <> 'CANCELLED'
          AND appointment_id <> NEW.appointment_id) THEN
        RAISE EXCEPTION 'Slot already taken';
    END IF;
    RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_clash
BEFORE INSERT OR UPDATE ON appointments
FOR EACH ROW EXECUTE FUNCTION trg_clash_fn();

Tests
CALL pr_book_appointment(2, 1, CURRENT_DATE + 1, '09:00');    -- works
-- CALL pr_book_appointment(3, 1, CURRENT_DATE, '09:00');     -- error: clash

-- (e) View: today's booked appointments
CREATE VIEW v_today_appointments AS
SELECT p.full_name AS patient, d.full_name AS doctor, a.slot_time
FROM appointments a
JOIN patients p ON p.patient_id = a.patient_id
JOIN doctors  d ON d.doctor_id  = a.doctor_id
WHERE a.appointment_day = CURRENT_DATE AND a.status = 'BOOKED';

SELECT * FROM v_today_appointments;

-- (f) Index: day + doctor (not unique, a doctor has many appointments)
-- Justification: the query filters both columns, so this index finds the rows fast.
CREATE INDEX idx_appt_day_doctor ON appointments (appointment_day, doctor_id);

SET enable_seqscan = off;
EXPLAIN SELECT * FROM appointments
WHERE appointment_day = CURRENT_DATE AND doctor_id = 1;
SET enable_seqscan = on;

(g) Scheduled job: count each status for a day
CREATE PROCEDURE pr_refresh_clinic_summary(p_day DATE)
LANGUAGE plpgsql AS $$
BEGIN
    INSERT INTO clinic_summary
    SELECT p_day,
           COUNT(*) FILTER (WHERE status = 'BOOKED'),
           COUNT(*) FILTER (WHERE status = 'ATTENDED'),
           COUNT(*) FILTER (WHERE status = 'CANCELLED')
    FROM appointments
    WHERE appointment_day = p_day
    ON CONFLICT (summary_date) DO UPDATE
    SET booked_count    = EXCLUDED.booked_count,
        attended_count  = EXCLUDED.attended_count,
        cancelled_count = EXCLUDED.cancelled_count;
END;
$$;

CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);
CALL pr_refresh_clinic_summary(CURRENT_DATE - 1);   -- rerun: one row only
SELECT * FROM clinic_summary;                       -- 0 booked, 2 attended, 1 cancelled

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('clinic_summary', '0 1 * * *',
    $$CALL q4_clinic.pr_refresh_clinic_summary(CURRENT_DATE - 1)$$);
SELECT * FROM cron.job;