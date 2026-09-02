-- Consolidated baseline: every context's schema in one file, replacing
-- the 15 incremental migrations that grew it (tickets #10-#32). The
-- pre-baseline history is gone deliberately — no deployment carries it,
-- and the roles remodel below rewrote the tenancy core, so replaying the
-- old chain then patching it would leave a schema no one ever designed.
--
-- Roles are now data, not a CHECK constraint list: `roles` is seeded
-- reference data every role-bearing column points at by foreign key, and
-- a single `role_assignments` table carries both scopes — platform
-- (superadmin, no tenant) and tenant (owner/operator/viewer). This
-- replaces the pre-baseline split where `users.platform_admin` was a
-- boolean beside a `memberships.role` CHECK that also (wrongly) allowed
-- 'platform-admin' as a membership value while the code documented the
-- opposite.

-- ---------------------------------------------------------------- tenancy

CREATE TABLE tenants (
    id uuid PRIMARY KEY,
    name text NOT NULL,
    slug text NOT NULL UNIQUE,
    -- NULL means unlimited (ticket #24), the default for every Tenant
    -- until a superadmin sets a cap.
    max_instances integer,
    max_storage_gi integer,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    -- A Tenant's slug IS its Kubernetes Namespace name verbatim (ticket
    -- #20), so Postgres enforces the same RFC 1123 label shape and the
    -- same reserved-name exclusion the application checks before ever
    -- reaching the cluster. "kube-*", "default", "argocd", and
    -- "cnpg-system" are namespaces the platform does not own outright.
    CONSTRAINT tenants_slug_rfc1123
        CHECK (slug ~ '^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'),
    CONSTRAINT tenants_slug_not_reserved
        CHECK (slug NOT LIKE 'kube-%' AND slug NOT IN ('default', 'argocd', 'cnpg-system')),
    CONSTRAINT tenants_max_instances_positive
        CHECK (max_instances IS NULL OR max_instances > 0),
    CONSTRAINT tenants_max_storage_gi_positive
        CHECK (max_storage_gi IS NULL OR max_storage_gi > 0)
);

CREATE TABLE users (
    id uuid PRIMARY KEY,
    username text NOT NULL UNIQUE,
    display_name text NOT NULL,
    email text NOT NULL UNIQUE,
    -- Set by a superadmin's ban action (ticket #18); kills live sessions
    -- and refuses sign-in without deleting the account.
    banned_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Seeded reference data, not a lookup table the application writes:
-- adding a role is a migration, and every role-bearing column below
-- points here so an unknown role name cannot be persisted anywhere.
-- scope is what makes the platform/tenant split explicit in data rather
-- than a rule living only in code comments.
CREATE TABLE roles (
    name text PRIMARY KEY,
    scope text NOT NULL CHECK (scope IN ('platform', 'tenant'))
);

INSERT INTO roles (name, scope) VALUES
    ('superadmin', 'platform'),
    ('owner', 'tenant'),
    ('operator', 'tenant'),
    ('viewer', 'tenant');

-- One table for both scopes: tenant_id NULL is a platform-scope
-- assignment (superadmin), NOT NULL is a role within that Tenant. The
-- scope CHECK is an equivalence, not two one-way rules — it rejects both
-- a superadmin pinned to a tenant and a tenant role with no tenant, so
-- the scope column in `roles` can never disagree with the row using it.
--
-- The surrogate id exists because Postgres forbids NULL in a primary
-- key; (tenant_id, user_id) stays unique for tenant rows, and because
-- NULLs never collide in a UNIQUE index, the platform-scope uniqueness
-- needs its own partial index below (without it one user could hold
-- several superadmin rows).
CREATE TABLE role_assignments (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    tenant_id uuid REFERENCES tenants (id) ON DELETE CASCADE,
    role text NOT NULL REFERENCES roles (name),
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT role_assignments_scope
        CHECK ((role = 'superadmin') = (tenant_id IS NULL)),
    UNIQUE (tenant_id, user_id)
);

CREATE UNIQUE INDEX role_assignments_platform_user_idx
    ON role_assignments (user_id) WHERE tenant_id IS NULL;
CREATE INDEX role_assignments_user_id_idx ON role_assignments (user_id);
CREATE INDEX role_assignments_tenant_id_idx ON role_assignments (tenant_id);

-- ------------------------------------------------------------------- auth

CREATE TABLE credentials (
    user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    password_hash text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE sessions (
    id uuid PRIMARY KEY,
    token_hash text NOT NULL UNIQUE,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    -- A session created by Impersonate (ticket #18) carries the admin who
    -- started it: /auth/me reads this to show the impersonation banner,
    -- and Exit resolves it to restore the admin's own session.
    impersonated_by uuid REFERENCES users (id) ON DELETE SET NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX sessions_user_id_idx ON sessions (user_id);

-- Single-use, expiring magic-link tokens (ticket #15). Request rate
-- limiting lives in Redis (ticket #25), never a row count here.
CREATE TABLE login_tokens (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    token_hash text NOT NULL UNIQUE,
    expires_at timestamptz NOT NULL,
    consumed_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX login_tokens_user_id_idx ON login_tokens (user_id);

-- totp_secrets.secret is stored in plaintext. Encrypting it at rest
-- would need an envelope-encryption/KMS story this platform doesn't have
-- yet; a hardcoded application-level key colocated with the ciphertext
-- buys no real defense over the Postgres access controls that already
-- protect password hashes and session tokens — anyone who can read this
-- column can also read the key sitting next to it. Revisit when a real
-- KMS-backed secrets story exists, not before.
CREATE TABLE totp_secrets (
    user_id uuid PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
    secret text NOT NULL,
    confirmed_at timestamptz,
    last_used_step bigint NOT NULL DEFAULT 0,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE totp_recovery_codes (
    id uuid PRIMARY KEY,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    code_hash text NOT NULL,
    used_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX totp_recovery_codes_user_id_idx ON totp_recovery_codes (user_id);

-- Its own table, not a repurposed sessions row: a much shorter TTL
-- (port.ChallengeTTL) and a different security property — resolving one
-- never proves a password was correct, only that a prior password or
-- magic-link step already did.
CREATE TABLE totp_challenges (
    id uuid PRIMARY KEY,
    token_hash text NOT NULL UNIQUE,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX totp_challenges_user_id_idx ON totp_challenges (user_id);

CREATE TABLE oauth_states (
    id uuid PRIMARY KEY,
    provider text NOT NULL,
    state_hash text NOT NULL,
    expires_at timestamptz NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- The lookup index matches Consume's guard exactly: provider +
-- state_hash.
CREATE UNIQUE INDEX oauth_states_provider_state_hash_idx
    ON oauth_states (provider, state_hash);

CREATE TABLE oauth_identities (
    id uuid PRIMARY KEY,
    provider text NOT NULL,
    provider_user_id text NOT NULL,
    user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    email text NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- One provider account links to at most one platform user, and a lookup
-- by provider+provider_user_id is every subsequent sign-in's fast path.
CREATE UNIQUE INDEX oauth_identities_provider_user_idx
    ON oauth_identities (provider, provider_user_id);
CREATE INDEX oauth_identities_user_id_idx ON oauth_identities (user_id);

-- Tenant-scoped API keys (ticket #16): an Operator+ mints a key at a role
-- no higher than their own; the secret is shown once and only key_hash is
-- ever persisted. A key-bound principal is pinned to tenant_id at role and
-- never gets the superadmin bypass, so the platform role is refused here
-- outright — the FK proves the role exists, the CHECK keeps this surface
-- tenant-scoped.
CREATE TABLE api_keys (
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    name text NOT NULL,
    key_prefix text NOT NULL,
    key_hash text NOT NULL UNIQUE,
    role text NOT NULL REFERENCES roles (name),
    created_by uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    last_used_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT api_keys_role_tenant_scoped CHECK (role <> 'superadmin')
);

CREATE INDEX api_keys_tenant_id_idx ON api_keys (tenant_id);

-- ------------------------------------------------------------ invitations

-- A tenant invitation is the only way an account comes into existence
-- besides the bootstrapped superadmin (ticket #10, #13). Owner+ invites
-- by email+role; the invitee accepts a single-use link to create their
-- account (or attach a role assignment to an existing one) and lands
-- signed in. Inviting someone as superadmin is not an invitation flow —
-- hence the same tenant-scoped CHECK api_keys carries.
CREATE TABLE invitations (
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    email text NOT NULL,
    role text NOT NULL REFERENCES roles (name),
    token_hash text NOT NULL UNIQUE,
    invited_by uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    expires_at timestamptz NOT NULL,
    accepted_at timestamptz,
    revoked_at timestamptz,
    created_at timestamptz NOT NULL DEFAULT now(),
    CONSTRAINT invitations_role_tenant_scoped CHECK (role <> 'superadmin')
);

CREATE INDEX invitations_tenant_id_idx ON invitations (tenant_id);

-- At most one pending (unaccepted, unrevoked) invitation per
-- (tenant, email), case-insensitively. Expired-but-still-pending rows are
-- deliberately still counted — re-inviting after expiry goes through the
-- accept-link expiry story, not a silent duplicate.
CREATE UNIQUE INDEX invitations_active_tenant_email_idx
    ON invitations (tenant_id, lower(email))
    WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- The admin console's Tenants surface asks, per Tenant, whether a seated
-- Owner assignment exists and whether a pending Owner invitation does
-- (ticket #21): both filter by (tenant_id, role) under the same pending
-- predicate, so a matching partial index serves them directly.
CREATE INDEX invitations_tenant_role_pending_idx ON invitations (tenant_id, role)
    WHERE accepted_at IS NULL AND revoked_at IS NULL;

-- ------------------------------------------------------------------ admin

CREATE TABLE audit_log (
    id uuid PRIMARY KEY,
    actor_user_id uuid NOT NULL REFERENCES users (id) ON DELETE CASCADE,
    action text NOT NULL,
    target_type text NOT NULL,
    target_id text,
    tenant_id uuid REFERENCES tenants (id) ON DELETE SET NULL,
    metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now()
);

-- List reads newest first; the actor index backs "actions by this admin"
-- without a full scan.
CREATE INDEX audit_log_created_at_idx ON audit_log (created_at DESC);
CREATE INDEX audit_log_actor_user_id_idx ON audit_log (actor_user_id, created_at DESC);

-- -------------------------------------------------------------- databases

-- Instance identity/intent only (ADR-0005). Phase, conditions, and
-- pods-ready are joined from the watch cache at read time, never stored.
CREATE TABLE instances (
    id uuid PRIMARY KEY,
    tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    engine text NOT NULL CHECK (engine IN ('redis', 'dragonfly', 'mongodb', 'postgres', 'clickhouse', 'elastic')),
    name text NOT NULL,
    version text NOT NULL,
    profile text NOT NULL,
    cpu_request text NOT NULL,
    memory_request text NOT NULL,
    -- Platform-accepted intent, not cluster-observed state (ADR-0005),
    -- exactly like cpu_request/memory_request: exact bytes parsed from
    -- the request's Kubernetes quantity, so a Tenant's max_storage_gi cap
    -- is enforced by summing this column without asking the cluster.
    storage_bytes bigint NOT NULL DEFAULT 0,
    pods_desired integer NOT NULL,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (tenant_id, name),
    CONSTRAINT instances_storage_bytes_nonnegative CHECK (storage_bytes >= 0)
);

CREATE INDEX instances_tenant_id_idx ON instances (tenant_id);

-- ---------------------------------------------------------------- compute

-- Compute Profile identity/intent only (ticket #31, ADR-0009):
-- platform-level capacity definitions that materialize exactly one
-- karpenter.sh/v1 NodePool each. Every field mirrors a NodePool spec
-- path directly (CONTEXT.md's Form Schema bargain: no sizing layer
-- between the fields and the CRD). The NodePool's live state is never
-- stored here (ADR-0005).
--
-- Four columns that earlier revisions of this table carried are absent
-- on purpose, and their absence is load-bearing rather than tidy.
-- instance_families and instance_sizes were narrowing axes an operator
-- assembled by hand beside the chosen types; Karpenter intersects
-- requirements, so a family excluding a chosen type produced a NodePool
-- that was valid to Kubernetes and could never launch a node, failing
-- silently until a pod waited forever for capacity that would not
-- arrive. instance_types replaces both as the single axis, validated
-- against what AWS actually offers in the configured region before the
-- NodePool is applied. capacity_type is gone because the purchase
-- option is not a per-profile choice: the platform runs on-demand only
-- (ADR-0008), since a spot reclamation kills a live database on two
-- minutes' notice through a door ADR-0006's disruption budget cannot
-- reach. raw_cr held a full-CR YAML escape hatch, removed entirely
-- (ADR-0009) — it was what made "every profile has exactly one
-- architecture" unanswerable, since a pasted document defines its own
-- requirements. labels and taints are gone because pinning derives from
-- the profile's own identity instead (ticket #41): selection rides
-- karpenter.sh/nodepool, which equals the profile's name by
-- construction, and exclusivity rides the platform's own taint carrying
-- that same name.
CREATE TABLE compute_profiles (
    id uuid PRIMARY KEY,
    -- name is both the profile's identity and its NodePool's own
    -- metadata.name: there is no separate resource name to keep in sync,
    -- and it is the join key an Instance's profile column matches.
    name text NOT NULL UNIQUE,
    node_class_ref text NOT NULL,
    -- instance_types are the exact machine shapes this pool may launch,
    -- rendered as one node.kubernetes.io/instance-type requirement.
    instance_types jsonb NOT NULL DEFAULT '[]'::jsonb,
    -- arch is the one CPU architecture this pool's nodes run (ADR-0009):
    -- exactly one value, never empty, and checked against every entry of
    -- instance_types before the row is written, since no instance type
    -- name exists under both architectures. It is also the axis the
    -- instance-type catalog is offered along, which is why it is stored
    -- rather than derived: the Profiles list answers "what does this run
    -- on" without an AWS call, and the applied NodePool says so without
    -- the reader knowing that a family letter g means Graviton.
    arch text NOT NULL CHECK (arch IN ('arm64', 'amd64')),
    expire_after text NOT NULL,
    consolidation_policy text NOT NULL CHECK (consolidation_policy IN ('WhenEmpty', 'WhenEmptyOrUnderutilized')),
    consolidate_after text NOT NULL,
    -- termination_grace_period is the ceiling on draining once a node
    -- has been disrupted (ADR-0006): it gives an operator's failover time
    -- to finish, and stops a drift-driven roll being blocked
    -- indefinitely by a workload's own disruption budget.
    termination_grace_period text NOT NULL DEFAULT '',
    disruption_budgets jsonb NOT NULL DEFAULT '[]'::jsonb,
    limits jsonb NOT NULL DEFAULT '{}'::jsonb,
    created_at timestamptz NOT NULL DEFAULT now(),
    updated_at timestamptz NOT NULL DEFAULT now()
);

-- Per-Tenant grants of Compute Profile use (ticket #32, CONTEXT.md:
-- "Tenants are granted use of profiles"). Granting and revoking is
-- superadmin only; a Tenant sees only its own granted profiles. The
-- unique pair makes granting an already-granted profile idempotent at the
-- database level too.
CREATE TABLE compute_profile_grants (
    id uuid PRIMARY KEY,
    profile_id uuid NOT NULL REFERENCES compute_profiles (id) ON DELETE CASCADE,
    tenant_id uuid NOT NULL REFERENCES tenants (id) ON DELETE CASCADE,
    created_at timestamptz NOT NULL DEFAULT now(),
    UNIQUE (profile_id, tenant_id)
);

CREATE INDEX compute_profile_grants_tenant_id_idx ON compute_profile_grants (tenant_id);
