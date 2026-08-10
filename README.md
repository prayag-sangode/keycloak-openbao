# OpenBao + Keycloak + Postgres Setup

This guide explains how to run **Keycloak** (with Postgres) and **OpenBao** side by side using Docker Compose, then integrate them via OIDC.

### Create config.hcl
```
cat > openbao/config.hcl

# ./openbao/config.hcl
auth "oidc" {
  type = "oidc"
}

# Storage backend: file-based (good for local dev)
storage "file" {
  path = "/opt/openbao/data"
}

# Listener: expose on all interfaces, disable TLS for dev
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}

# Allow running inside Docker without mlock
disable_mlock = true

# Enable the web UI
ui = true

```

## Docker Compose Setup

`docker-compose.yaml`:

```yaml
services:
  postgres:
    image: postgres:15
    container_name: postgres
    restart: always
    environment:
      POSTGRES_USER: keycloak
      POSTGRES_PASSWORD: keycloak
      POSTGRES_DB: keycloak
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

  keycloak:
    image: quay.io/keycloak/keycloak:24.0.5
    container_name: keycloak
    restart: always
    command: start-dev   # Development mode (no TLS required)
    environment:
      KC_DB: postgres
      KC_DB_URL: jdbc:postgresql://postgres:5432/keycloak
      KC_DB_USERNAME: keycloak
      KC_DB_PASSWORD: keycloak
      KEYCLOAK_ADMIN: admin
      KEYCLOAK_ADMIN_PASSWORD: admin
    ports:
      - "8080:8080"
    depends_on:
      - postgres
    volumes:
      - keycloak_data:/opt/keycloak/data

  openbao:
    image: openbao/openbao:latest
    container_name: openbao
    restart: always
    command: server -config=/etc/openbao/config.hcl
    ports:
      - "8200:8200"
    cap_add:
      - IPC_LOCK
    volumes:
      - ./openbao/config.hcl:/etc/openbao/config.hcl
      - ./openbao/data:/opt/openbao/data

volumes:
  postgres_data:
  keycloak_data:
  openbao_data:
```

Start everything:

```bash
docker-compose up -d
```

## Disable https in postgres

```
psql -U keycloak -d keycloak

UPDATE realm
SET ssl_required = 'NONE'
WHERE name = 'master';

SELECT name, ssl_required FROM realm WHERE name = 'master';

docker restart keycloak
```

## Keycloak Configuration

1. Access Keycloak Admin Console:  
   ```
   http://80.158.43.175:8080
   ```
   Login with:
   - Username: `admin`
   - Password: `admin`

2. Create a new client for OpenBao:
   - Go to **Clients → Create**  
   - Client ID: `openbao-client`  
   - Client Protocol: `openid-connect`  
   - Access Type: `confidential`  
   - Root URL: `http://80.158.43.175:8200`  
   - Home URL: `http://80.158.43.175:8200/ui`  
   - Valid Redirect URIs:  
     ```
     http://80.158.43.175:8200/ui/vault/auth/oidc/oidc/callback
     http://80.158.43.175:8200/*
     ```
   - Save and copy the **client secret**.

---

## OpenBao Initialization

Initialize:

```bash
chmod -R 777 openbao
docker exec -it openbao bao operator init -address=http://127.0.0.1:8200
```

Example output:

```
Unseal Key 1: <key1>
Unseal Key 2: <key2>
Unseal Key 3: <key3>
Unseal Key 4: <key4>
Unseal Key 5: <key5>

Initial Root Token: <root-token>
```

Unseal with 3 keys:

```bash
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200 <key1>
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200 <key2>
docker exec -it openbao bao operator unseal -address=http://127.0.0.1:8200 <key3>
```

Login with root token:

```bash
export BAO_ADDR=http://127.0.0.1:8200
bao login <root-token>
```


## Enable OIDC in OpenBao

Enable OIDC:

```bash
bao auth enable oidc
```

Configure OIDC:

```bash
bao write auth/oidc/config \
  oidc_discovery_url="http://80.158.43.175:8080/realms/master" \
  oidc_client_id="openbao-client" \
  oidc_client_secret="gImTEydyBUWJZ7UaCiCM6xs4TEqBz1Tw" \
  default_role="default"
```

Create role:

```bash
bao write auth/oidc/role/default \
  bound_audiences="openbao-client" \
  allowed_redirect_uris="http://80.158.43.175:8200/ui/vault/auth/oidc/oidc/callback" \
  user_claim="preferred_username" \
  policies="default"
```

## Test Login

- **CLI:**
  ```bash
  export BAO_ADDR=http://80.158.43.175:8200
  bao login -method=oidc
  ```

- **UI:**  
  Open `http://80.158.43.175:8200/ui` → select **OIDC** → authenticate via Keycloak.

## Outcome

- Postgres runs Keycloak DB.  
- Keycloak is configured with `openbao-client`.  
- OpenBao is initialized, unsealed, and integrated with Keycloak via OIDC.  
- Users can log into OpenBao using Keycloak credentials.

---

## KV v2 Curl Cheat Sheet


- **Write a secret**
  ```bash
  curl \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"data":{"value":"world"}}' \
    $BAO_ADDR/v1/secret/data/hello
  ```

- **Read a secret**
  ```bash
  curl \
    -H "X-Vault-Token: $BAO_TOKEN" \
    $BAO_ADDR/v1/secret/data/hello
  ```

- **List secrets**
  ```bash
  curl \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -X LIST \
    $BAO_ADDR/v1/secret/metadata/
  ```

- **Delete a version (soft delete)**
  ```bash
  curl \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"versions":[1]}' \
    $BAO_ADDR/v1/secret/delete/hello
  ```

- **Undelete a version**
  ```bash
  curl \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"versions":[1]}' \
    $BAO_ADDR/v1/secret/undelete/hello
  ```

- **Destroy a version (permanent)**
  ```bash
  curl \
    -H "X-Vault-Token: $BAO_TOKEN" \
    -H "Content-Type: application/json" \
    -X POST \
    -d '{"versions":[1]}' \
    $BAO_ADDR/v1/secret/destroy/hello
  ```

---


## Notes

- Store **unseal keys** and **root token** securely.  
- For production, enable HTTPS and set `sslRequired=EXTERNAL` in Keycloak.  
- Map Keycloak groups/roles to OpenBao policies for fine‑grained access control.
  

