# WordPress on Docker

WordPress (PHP-FPM) with MariaDB, Redis and an nginx reverse proxy, one isolated instance per site. The service stores its content in MariaDB and exposes CRUD operations on posts through the WordPress REST API.

Requirements: Docker Engine with the Compose plugin, `bash`, `openssl`.

## 1. Create a site

```bash
./new-site.sh demo demo.test --test --port 8443
```

This creates `sites/demo/` with the settings (`.env`) and generated secrets.
`--test` uses a self-signed certificate instead of the Cloudflare one.

## 2. Build

```bash
docker compose --env-file sites/demo/.env build
```

## 3. Deploy

```bash
docker compose --env-file sites/demo/.env up -d
docker compose --env-file sites/demo/.env ps      # wait until all services are healthy
```

## 4. Check it works

```bash
echo "127.0.0.1 demo.test" | sudo tee -a /etc/hosts
curl -k -I https://demo.test:8443/
```

Open `https://demo.test:8443/wp-admin/`. The user is `demo-admin` and the password is in
`sites/demo/secrets/wp_admin_password`.

CRUD on posts through the REST API:

```bash
APP=$(docker compose --env-file sites/demo/.env exec -T updater \
      wp --allow-root user application-password create demo-admin crud --porcelain)
API=https://demo.test:8443/wp-json/wp/v2/posts

curl -k -u "demo-admin:$APP" -X POST -H 'Content-Type: application/json' \
     -d '{"title":"Hello","status":"publish"}' $API                                   # create
curl -k -u "demo-admin:$APP" $API/<id>                                                 # read
curl -k -u "demo-admin:$APP" -X POST -H 'Content-Type: application/json' \
     -d '{"title":"Updated"}' $API/<id>                                                # update
curl -k -u "demo-admin:$APP" -X DELETE "$API/<id>?force=true"                          # delete
```

## 5. Stop

```bash
docker compose --env-file sites/demo/.env down       # keep the data
docker compose --env-file sites/demo/.env down -v    # also delete the volumes
```
