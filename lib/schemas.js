// Shared schema fragments
const recurrenceSchema = {
  type: "object",
  description: "Recurrence rule for repeating events/reminders",
  properties: {
    frequency: {
      type: "string",
      enum: ["daily", "weekly", "monthly", "yearly", "none"],
      description: "How often it repeats. Use 'none' to remove recurrence.",
    },
    interval: { type: "number", description: "Repeat every N periods (default: 1)" },
    endDate: { type: "string", description: "Stop repeating after this date (ISO format)" },
    occurrenceCount: { type: "number", description: "Stop after N occurrences" },
    daysOfTheWeek: {
      type: "array",
      items: { type: "string" },
      description: "Days for weekly recurrence (e.g., ['monday', 'wednesday', 'friday'])",
    },
    daysOfTheMonth: {
      type: "array",
      items: { type: "number" },
      description: "Days for monthly recurrence (e.g., [1, 15])",
    },
  },
  required: ["frequency"],
};

// Cross-cutting parameters shared by all tools
const agentDXProperties = {
  fields: {
    type: "array",
    items: { type: "string" },
    description: "Limit returned fields to these keys (e.g., [\"id\", \"title\", \"start\"]). Reduces token usage. The 'id' field is always included. Requesting 'start'/'startDate' auto-includes 'localStart'; requesting 'end'/'endDate' auto-includes 'localEnd'.",
  },
  dryRun: {
    type: "boolean",
    description: "If true, validate inputs and return a preview of what the operation would do without executing it. Only applies to mutation actions (create, update, delete, send, etc.).",
  },
};

// Consolidated tool definitions (5 tools replacing 40)
export const tools = [
  {
    name: "calendar",
    description:
      "Manage macOS calendar events. Actions: list (calendars), events (query by date range), get (by ID), search (by text), create, update, delete, batch_create, schema (show input schema).",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["list", "events", "get", "search", "create", "update", "delete", "batch_create", "schema"],
          description: "Operation to perform",
        },
        ...agentDXProperties,
        id: { type: "string", description: "Event ID (get/update/delete)" },
        calendar: { type: "string", description: "Calendar name or ID" },
        query: { type: "string", description: "Search query (search)" },
        from: { type: "string", description: "Start date (events/search)" },
        to: { type: "string", description: "End date (events/search)" },
        lastDays: { type: "number", description: "Include events from N days ago" },
        nextDays: { type: "number", description: "Include events up to N days ahead" },
        limit: { type: "number", description: "Maximum results" },
        title: { type: "string", description: "Event title (create/update)" },
        start: { type: "string", description: "Start date/time (create/update)" },
        end: { type: "string", description: "End date/time (create/update)" },
        duration: { type: "number", description: "Duration in minutes (create)" },
        location: { type: "string", description: "Event location" },
        notes: { type: "string", description: "Event notes" },
        allDay: { type: "boolean", description: "All-day event" },
        alarm: { type: "array", items: { type: "number" }, description: "Alarm minutes before event" },
        url: { type: "string", description: "URL" },
        attendees: {
          type: "array",
          description: "Event attendees (create/update). Replaces all existing attendees on update.",
          items: {
            type: "object",
            properties: {
              email: { type: "string", description: "Email address (required)" },
              name: { type: "string", description: "Display name" },
              role: { type: "string", description: "required, optional, chair, or nonParticipant" },
            },
            required: ["email"],
          },
        },
        recurrence: recurrenceSchema,
        futureEvents: { type: "boolean", description: "Apply to future occurrences (update/delete recurring)" },
        configDir: { type: "string", description: "Override PIM config directory (OpenClaw only — ignored by MCP server)" },
        profile: { type: "string", description: "Override PIM profile name (OpenClaw only — MCP server uses APPLE_PIM_PROFILE env)" },
        events: {
          type: "array",
          description: "Events array (batch_create)",
          items: {
            type: "object",
            properties: {
              title: { type: "string" },
              start: { type: "string" },
              end: { type: "string" },
              duration: { type: "number" },
              calendar: { type: "string" },
              location: { type: "string" },
              notes: { type: "string" },
              url: { type: "string" },
              allDay: { type: "boolean" },
              alarm: { type: "array", items: { type: "number" } },
              attendees: {
                type: "array",
                items: {
                  type: "object",
                  properties: {
                    email: { type: "string" },
                    name: { type: "string" },
                    role: { type: "string", description: "required, optional, chair, or nonParticipant" },
                  },
                  required: ["email"],
                },
                description: "Event attendees (batch_create)",
              },
              recurrence: recurrenceSchema,
            },
            required: ["title", "start"],
          },
        },
      },
      required: ["action"],
    },
  },

  {
    name: "reminder",
    description:
      "Manage macOS reminders. Actions: lists (all lists), items (list reminders with optional filter), get (by ID), search (by text), create, complete, update, delete, batch_create, batch_complete, batch_delete, schema (show input schema).",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: [
            "lists", "items", "get", "search", "create",
            "complete", "update", "delete",
            "batch_create", "batch_complete", "batch_delete",
            "schema",
          ],
          description: "Operation to perform",
        },
        ...agentDXProperties,
        id: { type: "string", description: "Reminder ID (get/complete/update/delete)" },
        ids: { type: "array", items: { type: "string" }, description: "Reminder IDs (batch_complete/batch_delete)" },
        list: { type: "string", description: "Reminder list name or ID" },
        filter: {
          type: "string",
          enum: ["overdue", "today", "tomorrow", "week", "upcoming", "completed", "all"],
          description: "Filter reminders by time (items)",
        },
        completed: { type: "boolean", description: "Include completed reminders" },
        lastDays: { type: "number", description: "Include reminders due from N days ago" },
        nextDays: { type: "number", description: "Include reminders due up to N days ahead" },
        limit: { type: "number", description: "Maximum results" },
        query: { type: "string", description: "Search query (search)" },
        title: { type: "string", description: "Reminder title (create/update)" },
        due: { type: "string", description: "Due date/time (create/update)" },
        notes: { type: "string", description: "Notes (create/update)" },
        priority: { type: "number", description: "Priority: 0=none, 1=high, 5=medium, 9=low" },
        // EKReminder.url is invisible in Apple Reminders on both iOS and macOS, so a link
        // written only there reaches EventKit clients and nobody else. The CLI mirrors it
        // into the notes, which Reminders does render and data-detect.
        url: {
          type: "string",
          description:
            "URL to attach (create/update, empty string to remove). Stored on EKReminder.url, " +
            "which Apple Reminders does not display, so it is also mirrored into the notes as a " +
            "visible link. Clearing the URL removes that mirrored line; unrelated updates leave " +
            "both untouched.",
        },
        urlInNotes: {
          type: "boolean",
          description:
            "Whether to mirror `url` into the notes as a visible link (default true). Set false " +
            "to store the URL for machine use only, accepting that nothing about it is visible " +
            "in Apple Reminders. Ignored when no url is supplied.",
        },
        alarm: { type: "array", items: { type: "number" }, description: "Alarm minutes before due. NOT an early heads-up: Apple Reminders shows a reminder at its earliest alarm, so 15 on a reminder due at 3:00 makes it read and fire at 2:45, with the due time shown nowhere. Use 0 to alert at the due date." },
        dueAlert: { type: "boolean", description: "Attach the alert Apple Reminders itself writes for a timed due date (an alarm at the due moment), so the reminder matches one created in the app. Default true. All-day due dates never get one, and an explicit alarm is left alone." },
        // No `required` here — empty object {} means "remove location" (batch_create has required since it doesn't support removal)
        location: {
          type: "object",
          description: "Location-based alarm (arrive/depart). Pass empty object to remove. Full location requires latitude, longitude, and proximity.",
          properties: {
            name: { type: "string", description: "Location name" },
            latitude: { type: "number" },
            longitude: { type: "number" },
            radius: { type: "number", description: "Geofence radius in meters (default: 100)" },
            proximity: { type: "string", enum: ["arrive", "depart"] },
          },
        },
        recurrence: recurrenceSchema,
        undo: { type: "boolean", description: "Mark as incomplete (complete/batch_complete)" },
        configDir: { type: "string", description: "Override PIM config directory (OpenClaw only — ignored by MCP server)" },
        profile: { type: "string", description: "Override PIM profile name (OpenClaw only — MCP server uses APPLE_PIM_PROFILE env)" },
        reminders: {
          type: "array",
          description: "Reminders array (batch_create)",
          items: {
            type: "object",
            properties: {
              title: { type: "string" },
              list: { type: "string" },
              due: { type: "string" },
              notes: { type: "string" },
              priority: { type: "number" },
              url: {
                type: "string",
                description:
                  "URL to attach. Stored on EKReminder.url (not displayed by Apple Reminders) " +
                  "and mirrored into the notes as a visible link.",
              },
              urlInNotes: {
                type: "boolean",
                description: "Mirror url into the notes as a visible link (default true).",
              },
              alarm: {
                type: "array",
                items: { type: "number" },
                description:
                  "Alarm minutes before due. Reminders shows a reminder at its earliest alarm, so a nonzero value moves the time the reminder displays and fires. Use 0 to alert at the due date.",
              },
              dueAlert: {
                type: "boolean",
                description:
                  "Attach the alert Apple Reminders itself writes for a timed due date (default true). All-day dues never get one.",
              },
              location: {
                type: "object",
                properties: {
                  name: { type: "string" },
                  latitude: { type: "number" },
                  longitude: { type: "number" },
                  radius: { type: "number" },
                  proximity: { type: "string", enum: ["arrive", "depart"] },
                },
                required: ["latitude", "longitude", "proximity"],
              },
              recurrence: recurrenceSchema,
            },
            required: ["title"],
          },
        },
      },
      required: ["action"],
    },
  },

  {
    name: "contact",
    description:
      "Manage macOS contacts. Actions: containers (list contact accounts), groups (list groups), list (list contacts), search (by name/email/phone), get (by ID with photo), create, update, delete, schema (show input schema).",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["containers", "groups", "list", "search", "get", "create", "update", "delete", "schema"],
          description: "Operation to perform",
        },
        ...agentDXProperties,
        id: { type: "string", description: "Contact ID (get/update/delete)" },
        group: { type: "string", description: "Group name or ID (list)" },
        query: { type: "string", description: "Search query (search)" },
        limit: { type: "number", description: "Maximum results" },
        name: { type: "string", description: "Full name (create, parsed into first/last)" },
        firstName: { type: "string" },
        lastName: { type: "string" },
        middleName: { type: "string" },
        namePrefix: { type: "string" },
        nameSuffix: { type: "string" },
        nickname: { type: "string" },
        previousFamilyName: { type: "string" },
        phoneticGivenName: { type: "string" },
        phoneticMiddleName: { type: "string" },
        phoneticFamilyName: { type: "string" },
        phoneticOrganizationName: { type: "string" },
        organization: { type: "string" },
        jobTitle: { type: "string" },
        department: { type: "string" },
        contactType: { type: "string", enum: ["person", "organization"] },
        email: { type: "string", description: "Simple email (uses 'work' label)" },
        phone: { type: "string", description: "Simple phone (uses 'main' label)" },
        emails: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              value: { type: "string" },
            },
            required: ["value"],
          },
        },
        phones: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              value: { type: "string" },
            },
            required: ["value"],
          },
        },
        addresses: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              street: { type: "string" },
              city: { type: "string" },
              state: { type: "string" },
              postalCode: { type: "string" },
              country: { type: "string" },
              isoCountryCode: { type: "string" },
              subLocality: { type: "string" },
              subAdministrativeArea: { type: "string" },
            },
          },
        },
        urls: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              value: { type: "string" },
            },
            required: ["value"],
          },
        },
        socialProfiles: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              service: { type: "string" },
              username: { type: "string" },
              url: { type: "string" },
              userIdentifier: { type: "string" },
            },
          },
        },
        instantMessages: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              service: { type: "string" },
              username: { type: "string" },
            },
          },
        },
        relations: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              name: { type: "string" },
            },
            required: ["name"],
          },
        },
        birthday: { type: "string", description: "YYYY-MM-DD or MM-DD format" },
        dates: {
          type: "array",
          items: {
            type: "object",
            properties: {
              label: { type: "string" },
              year: { type: "number" },
              month: { type: "number" },
              day: { type: "number" },
            },
            required: ["month", "day"],
          },
        },
        notes: { type: "string" },
        container: { type: "string", description: "Target container/account name for create" },
        configDir: { type: "string", description: "Override PIM config directory (OpenClaw only — ignored by MCP server)" },
        profile: { type: "string", description: "Override PIM profile name (OpenClaw only — MCP server uses APPLE_PIM_PROFILE env)" },
      },
      required: ["action"],
    },
  },

  {
    name: "mail",
    description:
      "Manage Mail.app messages. Requires Mail.app to be running. Actions: accounts, mailboxes, messages (list with attachmentCount), get (full message by ID with attachment metadata), search, update (flags), move, delete, batch_update, batch_delete, send (with optional attachments), reply (with optional attachments), save_attachment (save message attachments to disk), auth_check, schema (show input schema). " +
      "messages/search/get return senderAddress and senderName (and replyToAddress/replyToName on get) alongside the joined sender string — use senderAddress for any routing, filtering, or trust decision, since a display name is sender-chosen and may itself look like an address. " +
      "auth_check returns evaluated: false when the DKIM/SPF checks never ran, which is not the same as running them and being unsure.",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: [
            "accounts", "mailboxes", "messages", "get", "search",
            "update", "move", "delete", "batch_update", "batch_delete",
            "send", "reply", "save_attachment", "auth_check",
            "schema",
          ],
          description: "Operation to perform",
        },
        ...agentDXProperties,
        id: { type: "string", description: "RFC 2822 message ID (get/update/move/delete/reply/save_attachment/auth_check)" },
        ids: { type: "array", items: { type: "string" }, description: "Message IDs (batch_update/batch_delete)" },
        account: { type: "string", description: "Account name" },
        mailbox: { type: "string", description: "Mailbox name" },
        limit: { type: "number", description: "Maximum results" },
        filter: {
          type: "string",
          enum: ["unread", "flagged", "all"],
          description: "Filter messages (messages action)",
        },
        since: {
          type: "string",
          description: "Only include messages received on or after this date (ISO 8601: YYYY-MM-DD or full datetime). Used with search action only.",
        },
        query: { type: "string", description: "Search query (search)" },
        field: {
          type: "string",
          enum: ["subject", "sender", "content", "all"],
          description: "Search field (search)",
        },
        format: {
          type: "string",
          enum: ["plain", "markdown"],
          description: "Body format (get)",
        },
        read: { type: "boolean", description: "Set read status (update/batch_update)" },
        flagged: { type: "boolean", description: "Set flagged status (update/batch_update)" },
        junk: { type: "boolean", description: "Set junk status (update/batch_update)" },
        toMailbox: { type: "string", description: "Destination mailbox (move)" },
        toAccount: { type: "string", description: "Destination account (move)" },
        to: { type: "array", items: { type: "string" }, description: "Recipient email addresses (send)" },
        subject: { type: "string", description: "Email subject (send)" },
        body: { type: "string", description: "Message body text (send/reply)" },
        cc: { type: "array", items: { type: "string" }, description: "CC addresses (send)" },
        bcc: { type: "array", items: { type: "string" }, description: "BCC addresses (send)" },
        from: { type: "string", description: "Sender email address for account selection (send)" },
        attachment: { type: "array", items: { type: "string" }, description: "File paths to attach (send/reply). DISABLED BY DEFAULT to prevent local-file exfiltration. Opt in by creating ~/.config/apple-pim/mail-attachments.json with {\"enabled\": true, \"allowedRoots\": [\"~/Downloads\"]}. Even when enabled, paths in ~/.ssh, ~/.aws, ~/.gnupg, ~/.kube, ~/.docker, ~/.secrets, etc. and files matching id_rsa/.netrc/.pgpass/*.pem/*.key/*secret*/*credential* are always refused. Symlinks are resolved to canonical paths before checking." },
        index: { type: "integer", minimum: 0, description: "Zero-based attachment index (save_attachment). Omit to save all attachments." },
        destDir: { type: "string", description: "Directory to save attachments into (save_attachment). Must be within home directory or system temp; sensitive subpaths (~/.ssh, ~/.aws, ~/.gnupg, ~/Library/LaunchAgents, ~/.config/apple-pim, etc.) are always refused even inside home. Defaults to system temp. Use dryRun: true to preview." },
        trustedSenders: { type: "string", description: "Path to trusted-senders.json (auth_check)" },
        configDir: { type: "string", description: "Override PIM config directory (OpenClaw only — ignored by MCP server)" },
        profile: { type: "string", description: "Override PIM profile name (OpenClaw only — MCP server uses APPLE_PIM_PROFILE env)" },
      },
      required: ["action"],
    },
  },

  {
    name: "apple-pim",
    description:
      "PIM system management. Actions: status (check authorization), authorize (request permissions), config_show (view config), config_init (discover calendars/lists), schema (show input schema).",
    inputSchema: {
      type: "object",
      properties: {
        action: {
          type: "string",
          enum: ["status", "authorize", "config_show", "config_init", "schema"],
          description: "Operation to perform",
        },
        domain: {
          type: "string",
          enum: ["calendars", "reminders", "contacts", "mail"],
          description: "Specific domain (authorize)",
        },
        profile: {
          type: "string",
          description: "PIM profile name (config_show/config_init). In OpenClaw, also used for per-call isolation.",
        },
        configDir: { type: "string", description: "Override PIM config directory (OpenClaw only — ignored by MCP server)" },
      },
      required: ["action"],
    },
  },
];

export { recurrenceSchema };
