---
name: firstmate-inbox
description: Post a firstmate inbox note and read its reply.
version: 1.0.0
metadata:
  hermes:
    tags: [Firstmate, Inbox]
    requires_toolsets: [terminal]
---

# Firstmate inbox

Use this skill when desktop or ops should hand one note to the main firstmate inbox and later read that note's reply.

The only command is the bridge script installed beside this file.
Do not send email, direct messages, or public posts.
Do not spend money, place an order, or call a payment tool.
Do not use any profile other than desktop or ops.

## Post

Run the command below with the terminal tool.
Use desktop or ops for the profile, matching the profile that is running.
Use 16 hex characters for the correlation.
Put the note text in a regular file and pass that path.
The script does not evaluate the file.

    FM_HERMES_SKILL_DIR=${HERMES_SKILL_DIR} bash ${HERMES_SKILL_DIR}/scripts/firstmate-inbox.sh post --profile desktop --corr <16-hex> --message-file <path>

Print the command stdout unchanged.
The stdout is one JSON object with the note id and the correlation id.
It does not contain a fleet reply.

## Read

After a reply has been recorded with `fm-inbox.sh reply`, run:

    FM_HERMES_SKILL_DIR=${HERMES_SKILL_DIR} bash ${HERMES_SKILL_DIR}/scripts/firstmate-inbox.sh read --profile desktop --corr <same-16-hex>

Print the command stdout unchanged.
If the outcome is pending or missing, say that no reply is available yet.
Do not invent a reply.

## Limits

This skill only posts a note and reads its reply.
It does not grant authority to pay, post publicly, send email, or direct-message anyone.
The script calls `fm-inbox.sh` note and receipts, and no model-backed inbox command.
