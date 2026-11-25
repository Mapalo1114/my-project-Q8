-- ICT371 Question 8: Transport Fleet Maintenance (PostgreSQL)
DROP SCHEMA IF EXISTS q8 CASCADE;
CREATE SCHEMA q8;
SET search_path TO q8, public;

-- (a) TABLES -------------------------------------------------------------
CREATE TABLE vehicles (
  vehicle_id            INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  registration          VARCHAR(15) NOT NULL UNIQUE,
  current_odometer      INT NOT NULL CHECK (current_odometer >= 0),
  last_service_odometer INT NOT NULL CHECK (last_service_odometer >= 0),
  CONSTRAINT chk_service_not_ahead CHECK (last_service_odometer <= current_odometer)
);

CREATE TABLE trips (
  trip_id        INT GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  vehicle_id     INT NOT NULL REFERENCES vehicles(vehicle_id),
  trip_on        DATE NOT NULL,
  start_odometer INT NOT NULL CHECK (start_odometer >= 0),
  end_odometer   INT NOT NULL CHECK (end_odometer >= 0)
);

CREATE TABLE service_alerts (
  vehicle_id       INT PRIMARY KEY REFERENCES vehicles(vehicle_id),
  km_since_service INT NOT NULL,
  flagged_on       DATE NOT NULL DEFAULT CURRENT_DATE
);

-- (b) FUNCTION -----------------------------------------------------------
CREATE OR REPLACE FUNCTION fn_service_due(p_vehicle_id INT)
RETURNS BOOLEAN AS $$
DECLARE
  v_current INT;
  v_last    INT;
BEGIN
  SELECT current_odometer, last_service_odometer INTO v_current, v_last
  FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;

  RETURN (v_current - v_last) >= 5000;
END;
$$ LANGUAGE plpgsql STABLE;

-- (c) PROCEDURE (does NOT touch the vehicle odometer; the trigger does) --
CREATE OR REPLACE PROCEDURE pr_record_trip(p_vehicle_id INT, p_trip_on DATE, p_start INT, p_end INT)
AS $$
BEGIN
  PERFORM 1 FROM vehicles WHERE vehicle_id = p_vehicle_id;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', p_vehicle_id;
  END IF;

  IF p_trip_on IS NULL OR p_start IS NULL OR p_end IS NULL THEN
    RAISE EXCEPTION 'Trip date, start and end odometer are required';
  END IF;

  IF p_end <= p_start THEN
    RAISE EXCEPTION 'end_odometer (%) must be greater than start_odometer (%)', p_end, p_start;
  END IF;

  INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
  VALUES (p_vehicle_id, p_trip_on, p_start, p_end);
END;
$$ LANGUAGE plpgsql;

-- (d) TRIGGER ------------------------------------------------------------
CREATE OR REPLACE FUNCTION trg_fn_trip_odometer() RETURNS TRIGGER AS $$
DECLARE
  v_current INT;
BEGIN
  IF NEW.start_odometer IS NULL OR NEW.end_odometer IS NULL
     OR NEW.start_odometer < 0 OR NEW.end_odometer <= NEW.start_odometer THEN
    RAISE EXCEPTION 'Invalid mileage: start %, end %', NEW.start_odometer, NEW.end_odometer;
  END IF;

  SELECT current_odometer INTO v_current
  FROM vehicles WHERE vehicle_id = NEW.vehicle_id FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Unknown vehicle: %', NEW.vehicle_id;
  END IF;

  IF NEW.start_odometer <> v_current THEN
    RAISE EXCEPTION 'Start odometer % does not match vehicle current odometer %',
      NEW.start_odometer, v_current;
  END IF;

  UPDATE vehicles SET current_odometer = NEW.end_odometer   -- updated exactly once per trip
  WHERE vehicle_id = NEW.vehicle_id;

  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_trip_odometer
BEFORE INSERT ON trips
FOR EACH ROW
EXECUTE FUNCTION trg_fn_trip_odometer();

-- (g) PROCEDURE: service alerts ------------------------------------------
CREATE OR REPLACE PROCEDURE pr_refresh_service_alerts()
AS $$
BEGIN
  -- insert a new alert or update the existing one (keeps the first flagged_on date)
  INSERT INTO service_alerts (vehicle_id, km_since_service, flagged_on)
  SELECT vehicle_id, current_odometer - last_service_odometer, CURRENT_DATE
  FROM vehicles
  WHERE current_odometer - last_service_odometer >= 5000
  ON CONFLICT (vehicle_id) DO UPDATE
    SET km_since_service = EXCLUDED.km_since_service;

  -- remove alerts for vehicles that are no longer due (e.g. after service)
  DELETE FROM service_alerts sa
  WHERE NOT EXISTS (
    SELECT 1 FROM vehicles v
    WHERE v.vehicle_id = sa.vehicle_id
      AND v.current_odometer - v.last_service_odometer >= 5000
  );
END;
$$ LANGUAGE plpgsql;

-- (a) SEED DATA (trigger is already installed) ---------------------------
INSERT INTO vehicles (registration, current_odometer, last_service_odometer) VALUES
  ('BAE 1234', 10000,  4000),   -- 6000 km since service: due
  ('BAF 5678', 20000, 18000),   -- 2000 km: not due
  ('BAG 9012',  7000,  3000);   -- 4000 km: will pass 5000 after its trips

CALL pr_record_trip(1, DATE '2026-11-18', 10000, 10200);
CALL pr_record_trip(1, DATE '2026-11-19', 10200, 10450);
CALL pr_record_trip(2, DATE '2026-11-18', 20000, 20300);
CALL pr_record_trip(2, DATE '2026-11-20', 20300, 20500);
CALL pr_record_trip(3, DATE '2026-11-19',  7000,  7600);
CALL pr_record_trip(3, DATE '2026-11-21',  7600,  8100);   -- now 5100 km since service

SELECT * FROM trips ORDER BY trip_id;
SELECT * FROM vehicles ORDER BY vehicle_id;

-- tests (each should raise an error)
-- SELECT fn_service_due(1);                               -- true
-- SELECT fn_service_due(2);                               -- false
-- SELECT fn_service_due(99);                              -- Unknown vehicle
-- CALL pr_record_trip(1, CURRENT_DATE, 10450, 10450);     -- end must be greater
-- CALL pr_record_trip(1, CURRENT_DATE, 9999, 10100);      -- start does not match odometer
-- INSERT INTO trips (vehicle_id, trip_on, start_odometer, end_odometer)
--   VALUES (1, CURRENT_DATE, 10450, 10300);               -- trigger blocks direct SQL

-- (e) VIEW ---------------------------------------------------------------
CREATE OR REPLACE VIEW v_service_due AS
SELECT registration, current_odometer - last_service_odometer AS km_since_service
FROM vehicles
WHERE current_odometer - last_service_odometer >= 5000;

SELECT * FROM v_service_due;

-- (f) INDEX --------------------------------------------------------------
-- Equality on vehicle_id first, range on trip_on second.
CREATE INDEX idx_trips_vehicle_date ON trips (vehicle_id, trip_on);

ANALYZE trips;
SET enable_seqscan = off;
EXPLAIN
SELECT * FROM trips
WHERE vehicle_id = 1 AND trip_on BETWEEN DATE '2026-11-18' AND DATE '2026-11-30';
RESET enable_seqscan;

-- (g) TEST AND SCHEDULE --------------------------------------------------
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                      -- vehicles 1 and 3

UPDATE vehicles SET last_service_odometer = current_odometer WHERE vehicle_id = 1;  -- serviced
CALL pr_refresh_service_alerts();
SELECT * FROM service_alerts;                      -- vehicle 1 alert removed

CREATE EXTENSION IF NOT EXISTS pg_cron;
SELECT cron.schedule('q8_refresh_service_alerts', '0 6 * * 1',   -- every Monday 06:00
  $$CALL q8.pr_refresh_service_alerts()$$);
