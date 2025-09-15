-- 0. Use a dedicated schema
CREATE SCHEMA IF NOT EXISTS sos;

-- 1. Required extensions
-- Run as a superuser or a role that can create extensions
CREATE EXTENSION IF NOT EXISTS "uuid-ossp" WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS postgis WITH SCHEMA public;
CREATE EXTENSION IF NOT EXISTS "pgcrypto" WITH SCHEMA public; -- for gen_random_uuid() if preferred

-- 2. USERS table (citizens, device owners, officers)
CREATE TABLE sos.users (
    user_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    username text,
    phone text,
    role text, -- 'citizen' | 'officer' | 'admin' | 'station'
    created_at timestamptz DEFAULT now(),
    metadata jsonb
);

-- 3. STATIONS (police stations)
CREATE TABLE sos.stations (
    station_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    name text NOT NULL,
    address text,
    geo geography(Point,4326) NOT NULL,
    contact_phone text,
    created_at timestamptz DEFAULT now(),
    metadata jsonb
);

CREATE INDEX idx_stations_geo ON sos.stations USING GIST (geo);

-- 4. POLICE UNITS / DEVICES
-- Each unit has a device id and a geolocation point stored as PostGIS geography
CREATE TABLE sos.police_units (
    unit_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    device_id text UNIQUE,               -- device identifier (from app registration)
    unit_name text,
    station_id uuid REFERENCES sos.stations(station_id),
    capabilities jsonb DEFAULT '{}'::jsonb, -- e.g. {"armed": true, "medical": true}
    current_geo geography(Point,4326),   -- last reported location (lon/lat)
    last_seen timestamptz,
    created_at timestamptz DEFAULT now(),
    metadata jsonb
);

CREATE INDEX idx_police_units_geo ON sos.police_units USING GIST (current_geo);

-- 5. UNIT STATUS (availability, locking assignment)
CREATE TABLE sos.unit_status (
    unit_status_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    unit_id uuid NOT NULL REFERENCES sos.police_units(unit_id) UNIQUE,
    status text NOT NULL DEFAULT 'available', -- 'available'|'on_call'|'busy'|'off_duty'
    status_updated_at timestamptz DEFAULT now(),
    current_alert_id uuid NULL, -- FK to alerts.alert_id when assigned
    workload integer DEFAULT 0,
    last_heartbeat timestamptz,
    CONSTRAINT chk_status CHECK (status IN ('available','on_call','busy','off_duty'))
);

-- Partial index optimizing available units spatial queries
CREATE INDEX idx_unit_status_available ON sos.unit_status (unit_id)
  WHERE status = 'available';

-- 6. ALERTS
CREATE TABLE sos.alerts (
    alert_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    user_id uuid REFERENCES sos.users(user_id),
    reporter_phone text,
    created_at timestamptz DEFAULT now(),
    lat double precision NOT NULL,
    lon double precision NOT NULL,
    location_geo geography(Point,4326) NOT NULL,
    alert_type text, -- e.g. 'assault','accident','medical'
    status text NOT NULL DEFAULT 'created', -- 'created'|'assigned'|'accepted'|'resolved'|'cancelled'
    assigned_unit_id uuid NULL REFERENCES sos.police_units(unit_id),
    assigned_station_id uuid NULL REFERENCES sos.stations(station_id),
    metadata jsonb,
    CONSTRAINT chk_alert_status CHECK (status IN ('created','assigned','accepted','resolved','cancelled'))
);

-- convenience index to speed spatial queries joining alerts->units
CREATE INDEX idx_alerts_location_geo ON sos.alerts USING GIST (location_geo);

-- 7. MEDIA STREAMS (tracks the live stream metadata)
CREATE TABLE sos.media_streams (
    stream_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    alert_id uuid REFERENCES sos.alerts(alert_id),
    device_id text,            -- reporting device id
    stream_type text,          -- 'webrtc'|'rtmp'|'rtsp'
    url text,                  -- tokenized URL or SDP blob (be careful with sizes)
    sdp text,
    started_at timestamptz DEFAULT now(),
    ended_at timestamptz,
    metadata jsonb
);

CREATE INDEX idx_media_alert ON sos.media_streams (alert_id);

-- 8. BLUETOOTH SCANS (results posted by device)
CREATE TABLE sos.bluetooth_scans (
    scan_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    alert_id uuid REFERENCES sos.alerts(alert_id),
    device_id text,
    scanned_at timestamptz DEFAULT now(),
    scan_results jsonb, -- array/object containing {mac:.., rssi:.., name:..}
    metadata jsonb
);

CREATE INDEX idx_bluetooth_alert ON sos.bluetooth_scans (alert_id);

-- 9. CONSENT LOG (immutable)
CREATE TABLE sos.consent_log (
    consent_id uuid PRIMARY KEY DEFAULT uuid_generate_v4(),
    request_id uuid,          -- cross-ref to request or media request id
    alert_id uuid REFERENCES sos.alerts(alert_id),
    device_id text,
    consent_given boolean,
    consent_ts timestamptz DEFAULT now(),
    actor text,               -- 'user' or 'device' or 'policy'
    metadata jsonb
);

-- 10. AUDIT LOG (append-only)
CREATE TABLE sos.audit_log (
    audit_id bigserial PRIMARY KEY,
    ts timestamptz DEFAULT now(),
    actor text,
    action text,
    resource_type text,
    resource_id text,
    payload jsonb
);
CREATE INDEX idx_audit_ts ON sos.audit_log (ts DESC);

-- 11. UTILITY: trigger to populate alerts.location_geo on insert
CREATE OR REPLACE FUNCTION sos.set_alert_location_geo() RETURNS trigger AS $$
BEGIN
  NEW.location_geo := ST_SetSRID(ST_MakePoint(NEW.lon, NEW.lat), 4326)::geography;
  RETURN NEW;
END;
$$ LANGUAGE plpgsql;

CREATE TRIGGER trg_alert_set_geo
  BEFORE INSERT ON sos.alerts
  FOR EACH ROW EXECUTE FUNCTION sos.set_alert_location_geo();


-- 12. Function: find and assign nearest available unit
-- This will:
--  - select candidate available units within radius (meters)
--  - order by distance and return the nearest
--  - lock the chosen unit row (FOR UPDATE SKIP LOCKED) and update unit_status/current_alert_id
--  - update alerts.assigned_unit_id and alerts.status to 'assigned'
--
-- Note: in production consider more complex scoring (ETA, workload). This function is minimal but atomic.
CREATE OR REPLACE FUNCTION sos.find_and_assign_nearest_unit(p_alert_id uuid, p_max_radius_m integer DEFAULT 10000)
RETURNS TABLE(assigned_unit uuid, distance_m double precision) AS $$
DECLARE
  v_alert RECORD;
  v_unit RECORD;
BEGIN
  SELECT * INTO v_alert FROM sos.alerts WHERE alert_id = p_alert_id FOR SHARE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Alert % not found', p_alert_id;
  END IF;

  -- candidate selection: join police_units -> unit_status where status = 'available'
  FOR v_unit IN
    SELECT pu.unit_id,
           pu.current_geo,
           ST_DistanceSphere(pu.current_geo::geometry, v_alert.location_geo::geometry) AS dist_m
    FROM sos.police_units pu
    JOIN sos.unit_status us ON us.unit_id = pu.unit_id
    WHERE us.status = 'available'
      AND pu.current_geo IS NOT NULL
      AND ST_DistanceSphere(pu.current_geo::geometry, v_alert.location_geo::geometry) <= p_max_radius_m
    ORDER BY dist_m
    FOR UPDATE SKIP LOCKED
  LOOP
    -- Attempt to assign this unit (update status atomically)
    UPDATE sos.unit_status
      SET status = 'on_call',
          current_alert_id = p_alert_id,
          status_updated_at = now()
      WHERE unit_id = v_unit.unit_id
        AND status = 'available'
    RETURNING unit_id INTO v_unit;

    IF FOUND THEN
      -- record assignment in alerts
      UPDATE sos.alerts
         SET assigned_unit_id = v_unit.unit_id,
             assigned_station_id = (SELECT station_id FROM sos.police_units WHERE unit_id = v_unit.unit_id),
             status = 'assigned'
       WHERE alert_id = p_alert_id;

      -- Write audit
      INSERT INTO sos.audit_log(actor, action, resource_type, resource_id, payload)
      VALUES ('system', 'assign_unit', 'alert', p_alert_id::text,
              jsonb_build_object('unit_id', v_unit.unit_id, 'distance_m', (ST_DistanceSphere(v_unit.current_geo::geometry, v_alert.location_geo::geometry))));

      RETURN QUERY SELECT v_unit.unit_id, ST_DistanceSphere(v_unit.current_geo::geometry, v_alert.location_geo::geometry);
      RETURN; -- assigned
    END IF;
    -- else continue loop to next candidate
  END LOOP;

  -- No unit found in radius
  RETURN;
END;
$$ LANGUAGE plpgsql STABLE;

-- 13. Usage example of the function (call it after inserting alert)
-- Begin transaction to ensure consistency as needed
-- SELECT * FROM sos.find_and_assign_nearest_unit('alert-uuid-here');

-- 14. Helper: update device location (example function)
CREATE OR REPLACE FUNCTION sos.upsert_device_location(p_device_id text, p_lat double precision, p_lon double precision, p_last_seen timestamptz DEFAULT now())
RETURNS void AS $$
BEGIN
  -- update police_units table
  INSERT INTO sos.police_units(device_id, current_geo, last_seen, created_at)
    VALUES (p_device_id, ST_SetSRID(ST_MakePoint(p_lon, p_lat), 4326)::geography, p_last_seen, now())
  ON CONFLICT (device_id) DO
    UPDATE SET current_geo = EXCLUDED.current_geo,
               last_seen = EXCLUDED.last_seen;
  -- update unit_status heartbeat
  UPDATE sos.unit_status us
    SET last_heartbeat = p_last_seen
    FROM sos.police_units pu
    WHERE pu.device_id = p_device_id AND us.unit_id = pu.unit_id;
END;
$$ LANGUAGE plpgsql;

-- 15. Example insertions (sample data)
INSERT INTO sos.users (username, phone, role) VALUES ('alice', '+911234567890', 'citizen');
INSERT INTO sos.users (username, phone, role) VALUES ('officer_john', '+911112223334', 'officer');

-- create a station
INSERT INTO sos.stations (name, address, geo, contact_phone)
VALUES ('Central Station', '123 Main St', ST_SetSRID(ST_MakePoint(77.5946,12.9716),4326)::geography, '+911234000000');

-- create a police unit and status
INSERT INTO sos.police_units (device_id, unit_name, station_id, current_geo, last_seen)
VALUES ('device-abc-123','Patrol-1', (SELECT station_id FROM sos.stations LIMIT 1), ST_SetSRID(ST_MakePoint(77.5920,12.9730),4326)::geography, now());

INSERT INTO sos.unit_status (unit_id, status, status_updated_at, last_heartbeat)
VALUES ((SELECT unit_id FROM sos.police_units WHERE device_id='device-abc-123'), 'available', now(), now());

-- create an alert
INSERT INTO sos.alerts (user_id, reporter_phone, lat, lon, alert_type)
VALUES ((SELECT user_id FROM sos.users WHERE username='alice'), '+911234567890', 12.9710, 77.5940, 'harassment');

-- find and assign nearest unit to the last alert
-- SELECT * FROM sos.find_and_assign_nearest_unit( (SELECT alert_id FROM sos.alerts ORDER BY created_at DESC LIMIT 1) );

-- 16. Performance / production suggestions (notes)
-- - Consider partitioning sos.alerts by time (monthly) if volume is large.
-- - Keep consent_log and audit_log append-only; consider separate archival storage (cold storage) after retention period.
-- - Use pgcrypto or application-layer encryption for PII (phone numbers) if required.
-- - Add RLS (Row Level Security) policies so only authorized roles can read sensitive tables (e.g., alerts, media_streams).
-- - Use Redis for fast ephemeral state (connected devices, locks) and Postgres for authoritative storage.
-- - Add VACUUM / autovacuum tuning for large tables.

-- 17. Example view: nearest_available_units for debugging / UI
CREATE OR REPLACE VIEW sos.nearest_available_units AS
SELECT pu.unit_id,
       pu.unit_name,
       us.status,
       pu.last_seen,
       ST_X(pu.current_geo::geometry) AS lon,
       ST_Y(pu.current_geo::geometry) AS lat
FROM sos.police_units pu
JOIN sos.unit_status us ON us.unit_id = pu.unit_id
WHERE us.status = 'available';

