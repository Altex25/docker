import os
from urllib.parse import quote

if not os.environ.get("DATABASE_URL") and os.environ.get("DATABASE_PASSWORD_FILE"):
    with open(os.environ["DATABASE_PASSWORD_FILE"], encoding="utf-8") as secret:
        password = quote(secret.read().strip(), safe="")
    os.environ["DATABASE_URL"] = "postgresql://{}:{}@{}:{}/{}".format(
        os.environ["DATABASE_USER"],
        password,
        os.environ["DATABASE_HOST"],
        os.environ.get("DATABASE_PORT", "5432"),
        os.environ["DATABASE_NAME"],
    )
