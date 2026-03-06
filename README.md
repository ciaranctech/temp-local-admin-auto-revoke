# Temporary Local Admin with Auto-Revoke (Jamf Pro)

A macOS bash script for enterprise environments that temporarily elevates a standard local user to admin and then automatically revokes admin rights after a configurable duration.

## Overview

This script provides controlled, time-bound local admin access by:

1. **Validating target user and duration**
2. **Granting temporary admin rights**
3. **Creating a LaunchDaemon-backed auto-revoke job**
4. **Automatically removing admin rights when timer expires**
5. **Logging all actions** for audit and troubleshooting

## Use Case

Ideal for organizations that need:

- just-in-time local admin access,
- automatic privilege rollback,
- strong audit trail,
- Jamf Self Service compatibility.

## Requirements

- **macOS**
- **Root context** (Jamf script execution)
- **Jamf Pro** deployment

## Installation (Jamf Pro)

1. Upload `temp-local-admin-auto-revoke.sh` as a Jamf script.
2. Add it to a policy or Self Service item.
3. Optional: set **Parameter 4** for duration override (minutes).
4. Scope to target devices/users.

## Jamf Parameters

- `$3`: logged-in username (Jamf standard)
- `$4`: elevation duration in minutes (optional)

If `$4` is not provided, default is 10 minutes.

## Script Configuration

Inside the script:

```bash
DEFAULT_ELEVATION_MINUTES=10
MAX_ELEVATION_MINUTES=120
COOLDOWN_MINUTES=5
```

You can tune these values to your policy requirements.

## v1.1 Enhancements

- Request ID generation per elevation event
- Root-owned state tracking under:
  - `/Library/Application Support/temp-local-admin-auto-revoke/state/`
- Cooldown window enforcement after revoke
- Optional ticket/justification capture (Jamf `$5`)
- Reconcile mode for stale grant cleanup:

```bash
RECONCILE_ONLY=1 /path/to/temp-local-admin-auto-revoke.sh
```

- Unified log marker entries via `logger -t temp-local-admin-auto-revoke`

## Safety Controls

- Must run as root.
- Rejects invalid duration.
- Rejects protected system users (`root`, `daemon`, `nobody`).
- Exits safely if user is already admin (avoids accidental demotion of permanent admins).
- If revoke-job setup fails, script rolls back admin grant.

## Log Location

Primary logs:

```
/Library/Application Support/Script Logs/temp-local-admin-auto-revoke/
```

Additional revoke-job logs are written to the same directory.

## How It Works

### Flow

```
Validate input → Grant admin → Create LaunchDaemon revoke job → Timer expires → Remove admin
```

### Technical Notes

- Uses `dseditgroup` for admin membership changes.
- Uses a temporary helper script + LaunchDaemon to ensure revoke is detached from Jamf process lifecycle.
- Removes helper artifacts after completion.

## Exit Codes

| Code | Description |
|------|-------------|
| 0 | Success |
| 1 | General failure |
| 2 | Not running as root |

## VM Testing Performed

Validated in dedicated macOS test VM with separate non-admin test user (`vmtestuser`):

1. Confirmed test user starts as standard.
2. Ran script with 1-minute elevation + justification (`CHG-12345`).
3. Confirmed immediate admin grant.
4. Confirmed auto-revoke after timer.
5. Confirmed cleanup of helper script and LaunchDaemon plist.
6. Confirmed state/cooldown file creation.
7. Re-ran within cooldown window and confirmed script safely blocked re-grant.

## Security Considerations

- Keep at least one dedicated VM admin account untouched for recovery.
- Use non-admin test user for execution validation.
- Keep elevation windows short.
- Review logs after each run for policy audit.

## Version History

| Version | Date | Changes |
|---------|------|---------|
| 1.0 | 2026-03-06 | Initial release |
| 1.1 | 2026-03-06 | Added state tracking, cooldown, reconcile mode, request IDs, and justification support |

## Author

**Ciaran Coghlan**

## License

Provided as-is for enterprise operational use. Validate in a controlled test VM before production rollout.
