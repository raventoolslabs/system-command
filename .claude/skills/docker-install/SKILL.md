---
name: docker-install
description: Use whenever installing/running any service via Docker in this project (e.g. "instala X con docker", "corre X en un contenedor"). Defines where the compose file and volumes go.
---

# Docker install convention

When the user asks to install or run something with Docker:

1. Do NOT use a bare `docker run`. Always create a `docker-compose.yml`.
2. Put each service in its own folder: `/opt/docker/<service-name>/docker-compose.yml`.
3. Volumes are always bind mounts rooted at that same base folder, never named
   Docker volumes and never paths outside `/opt/docker/<service-name>/`.
   Example: `./data:/root/.ollama`, not a top-level named volume.
4. Bring it up with `docker compose up -d` from inside `/opt/docker/<service-name>/`.

Example layout:

```
/opt/docker/ollama/
├── docker-compose.yml
└── data/            # bind-mounted volume contents
```
