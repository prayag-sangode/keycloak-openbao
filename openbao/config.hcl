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
