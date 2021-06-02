#!/bin/sh -e

if [ -z "$DB_HOST" -o -z "$DB_ROOT_PASSWORD" -o -z "$DB_NAME" -o -z "$DB_USER" -o -z "$DB_PASSWORD" ]; then
    echo >&2 'error: database is uninitialized and password option is not specified or OBS'
    echo >&2 '  You need to specify DB_HOST, DB_ROOT_PASSWORD, DB_NAME, DB_USER and DB_PASSWORD'
    exit 1
fi

cat > config/database.yml <<EOF
production:
  adapter: mysql2
  host: $DB_HOST
  port: 3306
  database: $DB_NAME
  username: $DB_USER
  password: $DB_PASSWORD
  encoding: utf8mb4
  collation: utf8mb4_unicode_ci
  timeout: 15
  pool: 30
EOF

rake() {
    runuser -u frontend -- bundle exec rake "$@"
}

if ! rake db:migrate:status
then
    rake db:create || true
    rake db:setup
    rake writeconfiguration
else
    rake db:migrate:with_data
fi
