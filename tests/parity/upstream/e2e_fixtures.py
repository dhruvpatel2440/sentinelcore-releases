"""Create dedicated end-to-end test accounts (one per role).

Used only by the E2E suite in `scripts/e2e_test.py`. Creates accounts under a
`t_` prefix so they are obviously test data and never collide with real users.
The bootstrap admin account is left untouched.

    python -m scripts.e2e_fixtures
"""

from __future__ import annotations

import asyncio

from sqlalchemy import select

from app.core.security import hash_password
from app.db.session import SessionLocal, engine
from app.models.user import User, UserRole

E2E_PASSWORD = "E2eTestPassw0rd!2026"

ACCOUNTS = [
    ("t_admin", UserRole.ADMIN),
    ("t_analyst", UserRole.ANALYST),
    ("t_viewer", UserRole.VIEWER),
]


async def seed() -> None:
    async with SessionLocal() as db:
        for username, role in ACCOUNTS:
            user = await db.scalar(select(User).where(User.username == username))
            if user is None:
                db.add(
                    User(
                        username=username,
                        email=f"{username}@e2e.test",
                        full_name=f"E2E {role.value}",
                        role=role,
                        password_hash=hash_password(E2E_PASSWORD),
                        is_active=True,
                    )
                )
            else:
                user.role = role
                user.is_active = True
                user.password_hash = hash_password(E2E_PASSWORD)
        await db.commit()
    await engine.dispose()
    print(f"e2e accounts ready: {', '.join(n for n, _ in ACCOUNTS)}")


if __name__ == "__main__":
    asyncio.run(seed())
