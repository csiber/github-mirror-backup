# GitHub Mirror Backup

A simple Bash-based backup engine that mirrors GitHub repositories to local storage using the GitHub API and Git over SSH.

It discovers all repositories accessible to the authenticated GitHub account, including private repositories, and maintains local bare Git mirrors.

## Features

* 🔐 GitHub API authentication with a Personal Access Token
* 🔑 SSH-based Git transport
* 📦 Mirrors private and public repositories
* 👥 Includes repositories owned by the user, collaborated on, or accessible through organizations
* 🔄 Incremental updates with `git remote update --prune`
* 🗑️ Detects repositories that are no longer visible on GitHub without deleting the local backup
* ⚠️ Keeps broken or invalid existing targets instead of overwriting them
* 🔒 Prevents concurrent backup runs
* 📋 Detailed terminal output and rotating log files
* 📊 Backup summary with repository counts, changes, failures, disk usage and duration
* ↩️ Returns meaningful exit codes for automation and scheduled jobs

## Requirements

* Bash 4.4+
* Git
* curl
* jq
* OpenSSH
* A GitHub Personal Access Token
* An SSH key registered with GitHub

The script was designed for Linux/NAS environments and works particularly well as a scheduled backup job.

## Setup

Create the token file:

```bash
mkdir -p ~/.config/github
chmod 700 ~/.config/github
nano ~/.config/github/token
```

Put the GitHub Personal Access Token into the file and secure it:

```bash
chmod 600 ~/.config/github/token
```

Make sure SSH authentication works:

```bash
ssh -T git@github.com
```

You should receive GitHub's successful authentication message.

Then configure the backup destination in `github-backup.sh`:

```bash
BASE="/path/to/backup"
```

Make the script executable:

```bash
chmod +x github-backup.sh
```

Run it:

```bash
./github-backup.sh
```

## How it works

The script uses two separate authentication methods:

**GitHub API → Personal Access Token**

The API is used to discover repositories available to the authenticated account.

**Git → SSH**

Repository data is transferred using each repository's SSH URL. The Personal Access Token is never embedded into Git URLs.

For a new repository, the script performs:

```bash
git clone --mirror
```

For an existing mirror, it performs an incremental update:

```bash
git remote update --prune
```

This keeps the local mirror synchronized with the repository's Git refs.

## Repository layout

By default, each repository is stored as a bare mirror:

```text
backup/
├── repository-one.git/
├── repository-two.git/
├── repository-three.git/
└── _logs/
    ├── github-backup-2026-09-28_08-00-00.log
    └── ...
```

If two repositories have the same name under different owners, the owner is added to avoid collisions:

```text
owner1__project.git
owner2__project.git
```

## Exit codes

| Code | Meaning                                               |
| ---: | ----------------------------------------------------- |
|  `0` | Backup completed successfully                         |
|  `1` | Backup completed, but one or more repositories failed |
|  `2` | Fatal error prevented the backup from completing      |

This makes the script suitable for cron, Synology Task Scheduler, monitoring systems, or other automation.

## What this backs up

The mirror contains the Git repository itself, including branches, tags and Git objects.

This script does **not** currently back up GitHub-specific metadata such as:

* Issues
* Pull request discussions
* Releases metadata
* Actions artifacts
* Packages
* Repository settings
* GitHub Wiki
* Git LFS objects unless separately fetched

Those are separate from the Git repository and require additional backup handling.

## Security

The GitHub token is read from a local file and passed to `curl` through stdin rather than being placed in the command line.

Do **not** commit the token file to Git.

Recommended permissions:

```bash
chmod 600 ~/.config/github/token
```

## License

MIT
