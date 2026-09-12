# Privacy Policy - che-apple-mail-mcp

## Overview

che-apple-mail-mcp is a local MCP (Model Context Protocol) server that provides email management capabilities through native AppleScript integration with Apple Mail. This document explains how your data is handled.

## Data Access

This MCP server accesses the following data on your Mac:

- **Emails**: Read, compose, reply, forward, delete emails in Mail.app
- **Mailboxes**: Read, create, delete mailboxes (folders)
- **Attachments**: List and save email attachments
- **Mail Rules**: Read, create, enable/disable, delete mail rules
- **Signatures**: Read email signatures
- **Accounts**: Read mail account information
- **VIP Senders**: Read VIP sender list

## Data Storage

**No data is stored** outside of Apple Mail.

- All email data remains in your Mail.app
- No data is written to external files, databases, or caches
- No data is transmitted to external servers or cloud services
- All operations are performed locally on your Mac via AppleScript

## Data Transmission

**No data is transmitted** to external services.

- che-apple-mail-mcp operates entirely offline
- All communication happens locally via MCP protocol (stdin/stdout)
- No network connections are made by this server
- No analytics, telemetry, or usage tracking

## Required Permissions

To function, che-apple-mail-mcp requires the following macOS permissions:

### Automation (AppleScript)
- **Purpose**: Control Mail.app application
- **Permission**: Allow automation of Mail
- **Grant via**: System Settings > Privacy & Security > Automation

On first use, macOS will automatically prompt for this permission.

## How to Grant Permissions

1. The first time you use a tool, macOS will prompt for **Automation** permission
2. Click "Allow" to enable AppleScript control of Mail.app
3. Alternatively, grant permissions manually:
   - Open **System Settings**
   - Navigate to **Privacy & Security** → **Automation**
   - Enable Mail access for the MCP server binary or Terminal/iTerm

## How to Revoke Access

If you wish to revoke access:

1. Open **System Settings**
2. Navigate to **Privacy & Security** → **Automation**
3. Disable Mail access for the MCP server

Alternatively, you can delete the MCP server binary from your system.

## Third-Party Services

This server does **not** connect to any third-party services:

- No cloud sync services
- No API calls to external servers
- No integration with non-local services
- No data sharing with third parties

## Open Source

che-apple-mail-mcp is open source software licensed under the MIT License. You can review the source code to verify these privacy practices:

- Repository: https://github.com/PsychQuant/che-apple-mail-mcp
- All code is available for inspection
- No hidden functionality
- No obfuscated network calls

## Updates to This Policy

This privacy policy may be updated as the software evolves. Any changes will be documented in the project's CHANGELOG.

## Contact

For questions or concerns about privacy, please open an issue on the project's GitHub repository.

---

*Last updated: 2026-01-15*
*Version: 1.0.0*
