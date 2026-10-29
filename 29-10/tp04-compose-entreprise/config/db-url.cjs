const fs = require('fs');

const env = process.env;

if (!env.DATABASE_URL && env.DATABASE_PASSWORD_FILE) {
  const password = encodeURIComponent(fs.readFileSync(env.DATABASE_PASSWORD_FILE, 'utf8').trim());
  env.DATABASE_URL = `postgres://${env.DATABASE_USER}:${password}@${env.DATABASE_HOST}:${env.DATABASE_PORT || 5432}/${env.DATABASE_NAME}`;
}
