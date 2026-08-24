export function buildCalendarDeleteArgs(args) {
  const deleteArgs = ["delete", "--id", args.id];
  if (args.futureEvents) deleteArgs.push("--future-events");
  return deleteArgs;
}

export function buildCalendarCreateArgs(args, targetCalendar) {
  const cliArgs = ["create", "--title", args.title, "--start", args.start];
  if (args.end) cliArgs.push("--end", args.end);
  if (args.duration) cliArgs.push("--duration", String(args.duration));
  if (targetCalendar) cliArgs.push("--calendar", targetCalendar);
  if (args.location) cliArgs.push("--location", args.location);
  if (args.notes) cliArgs.push("--notes", args.notes);
  if (args.url) cliArgs.push("--url", args.url);
  if (args.allDay) cliArgs.push("--all-day");
  if (args.alarm) {
    for (const minutes of args.alarm) {
      const val = Math.abs(Number(minutes));
      if (Number.isFinite(val)) cliArgs.push("--alarm", String(val));
    }
  }
  if (args.recurrence) {
    cliArgs.push("--recurrence", JSON.stringify(args.recurrence));
  }
  if (args.attendees) {
    cliArgs.push("--attendees", JSON.stringify(args.attendees));
  }
  return cliArgs;
}

export function buildCalendarUpdateArgs(args) {
  const cliArgs = ["update", "--id", args.id];
  if (args.title) cliArgs.push("--title", args.title);
  if (args.start) cliArgs.push("--start", args.start);
  if (args.end) cliArgs.push("--end", args.end);
  if (args.location) cliArgs.push("--location", args.location);
  if (args.notes) cliArgs.push("--notes", args.notes);
  if (args.url) cliArgs.push("--url", args.url);
  if (args.recurrence) cliArgs.push("--recurrence", JSON.stringify(args.recurrence));
  if (args.attendees) cliArgs.push("--attendees", JSON.stringify(args.attendees));
  if (args.futureEvents) cliArgs.push("--future-events");
  return cliArgs;
}

export function buildReminderCreateArgs(args, targetList) {
  const cliArgs = ["create", "--title", args.title];
  if (targetList) cliArgs.push("--list", targetList);
  if (args.due) cliArgs.push("--due", args.due);
  if (args.notes) cliArgs.push("--notes", args.notes);
  if (args.priority !== undefined) cliArgs.push("--priority", String(args.priority));
  if (args.url) cliArgs.push("--url", args.url);
  // Apple Reminders never draws EKReminder.url, so the CLI mirrors it into the notes by
  // default. Callers storing a machine-only link need a way to say so.
  if (args.url && args.urlInNotes === false) cliArgs.push("--no-url-in-notes");
  if (args.alarm) {
    for (const minutes of args.alarm) {
      const val = Math.abs(Number(minutes));
      if (Number.isFinite(val)) cliArgs.push("--alarm", String(val));
    }
  }
  if (args.location) cliArgs.push("--location", JSON.stringify(args.location));
  if (args.recurrence) cliArgs.push("--recurrence", JSON.stringify(args.recurrence));
  return cliArgs;
}

export function buildReminderUpdateArgs(args) {
  const cliArgs = ["update", "--id", args.id];
  if (args.title) cliArgs.push("--title", args.title);
  if (args.due) cliArgs.push("--due", args.due);
  if (args.notes) cliArgs.push("--notes", args.notes);
  if (args.priority !== undefined) cliArgs.push("--priority", String(args.priority));
  if (args.url !== undefined) cliArgs.push("--url", args.url);
  if (args.url !== undefined && args.urlInNotes === false) cliArgs.push("--no-url-in-notes");
  if (args.location) cliArgs.push("--location", JSON.stringify(args.location));
  if (args.recurrence) cliArgs.push("--recurrence", JSON.stringify(args.recurrence));
  return cliArgs;
}

function pushJSONIfNonEmpty(cliArgs, flag, value) {
  if (Array.isArray(value) && value.length > 0) {
    cliArgs.push(flag, JSON.stringify(value));
  }
}

function pushContactSharedFields(cliArgs, args) {
  if (args.firstName) cliArgs.push("--first-name", args.firstName);
  if (args.lastName) cliArgs.push("--last-name", args.lastName);
  if (args.middleName) cliArgs.push("--middle-name", args.middleName);
  if (args.namePrefix) cliArgs.push("--name-prefix", args.namePrefix);
  if (args.nameSuffix) cliArgs.push("--name-suffix", args.nameSuffix);
  if (args.nickname) cliArgs.push("--nickname", args.nickname);
  if (args.previousFamilyName) cliArgs.push("--previous-family-name", args.previousFamilyName);
  if (args.phoneticGivenName) cliArgs.push("--phonetic-given-name", args.phoneticGivenName);
  if (args.phoneticMiddleName) cliArgs.push("--phonetic-middle-name", args.phoneticMiddleName);
  if (args.phoneticFamilyName) cliArgs.push("--phonetic-family-name", args.phoneticFamilyName);
  if (args.phoneticOrganizationName) cliArgs.push("--phonetic-organization-name", args.phoneticOrganizationName);
  if (args.organization) cliArgs.push("--organization", args.organization);
  if (args.jobTitle) cliArgs.push("--job-title", args.jobTitle);
  if (args.department) cliArgs.push("--department", args.department);
  if (args.contactType) cliArgs.push("--contact-type", args.contactType);
  if (args.email) cliArgs.push("--email", args.email);
  if (args.phone) cliArgs.push("--phone", args.phone);
  pushJSONIfNonEmpty(cliArgs, "--emails", args.emails);
  pushJSONIfNonEmpty(cliArgs, "--phones", args.phones);
  pushJSONIfNonEmpty(cliArgs, "--addresses", args.addresses);
  pushJSONIfNonEmpty(cliArgs, "--urls", args.urls);
  pushJSONIfNonEmpty(cliArgs, "--social-profiles", args.socialProfiles);
  pushJSONIfNonEmpty(cliArgs, "--instant-messages", args.instantMessages);
  pushJSONIfNonEmpty(cliArgs, "--relations", args.relations);
  if (args.birthday) cliArgs.push("--birthday", args.birthday);
  pushJSONIfNonEmpty(cliArgs, "--dates", args.dates);
  if (args.notes) cliArgs.push("--notes", args.notes);
}

export function buildContactCreateArgs(args) {
  const cliArgs = ["create"];
  if (args.name) cliArgs.push("--name", args.name);
  if (args.container) cliArgs.push("--container", args.container);
  pushContactSharedFields(cliArgs, args);
  return cliArgs;
}

export function buildContactUpdateArgs(args) {
  const cliArgs = ["update", "--id", args.id];
  pushContactSharedFields(cliArgs, args);
  return cliArgs;
}
