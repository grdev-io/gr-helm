-- Licensing context (BYOC licensing plan): a single-row table holding
-- this deployment's own stable identity plus the most recently
-- verified license and CRL JWS (internal/licensing/port.LicenseStore).
-- A restart with no network reachable to gr-licensing reads this back
-- and keeps enforcing from what it last verified, rather than falling
-- all the way to the bootstrap floor (Frozen). id is pinned to 1 by
-- its own CHECK, so the table can never hold more than the one row
-- every LicenseStore method reads and writes.
CREATE TABLE license_state (
    id smallint PRIMARY KEY DEFAULT 1,
    plane_id uuid NOT NULL,
    license_jws text,
    crl_jws text,
    updated_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT license_state_singleton CHECK (id = 1)
);
