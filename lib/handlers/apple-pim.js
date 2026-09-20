export async function handleApplePim(args, runCLI) {
  switch (args.action) {
    case "status": {
      const status = {};
      const domains = [
        { name: "calendars", cli: "calendar-cli" },
        { name: "reminders", cli: "reminder-cli" },
        { name: "contacts", cli: "contacts-cli" },
        { name: "mail", cli: "mail-cli" },
      ];

      const statusMessages = {
        authorized: "Full access granted",
        notDetermined: "Permission not yet requested. Run authorize to prompt.",
        denied: "Access denied. Enable in System Settings > Privacy & Security.",
        restricted: "Access restricted by system policy (MDM or parental controls).",
        writeOnly: "Write-only access. Upgrade in System Settings > Privacy & Security.",
        unavailable: "Not available",
      };

      for (const domain of domains) {
        try {
          const result = await runCLI(domain.cli, ["auth-status"]);
          const auth = result.authorization || "unknown";
          // OS permission state is not a credential. Keep the shipped authorization
          // field for consumers, but expose permissionStatus for secret-redacting hosts.
          status[domain.name] = {
            enabled: true,
            permissionStatus: auth,
            authorization: auth,
            message: result.message || statusMessages[auth] || `Status: ${auth}`,
          };
        } catch (err) {
          status[domain.name] = {
            enabled: false,
            permissionStatus: "error",
            authorization: "error",
            message: err.message,
          };
        }
      }

      return { status };
    }

    case "authorize": {
      const targetDomain = args.domain;
      const results = {};
      const domains = [
        { name: "calendars", cli: "calendar-cli", args: ["list"] },
        { name: "reminders", cli: "reminder-cli", args: ["lists"] },
        { name: "contacts", cli: "contacts-cli", args: ["groups"] },
        { name: "mail", cli: "mail-cli", args: ["accounts"] },
      ];

      const toAuthorize = targetDomain
        ? domains.filter((d) => d.name === targetDomain)
        : domains;

      for (const domain of toAuthorize) {
        try {
          await runCLI(domain.cli, domain.args);
          results[domain.name] = { success: true, message: "Access authorized" };
        } catch (err) {
          const msg = err.message.toLowerCase();
          if (msg.includes("denied") || msg.includes("not granted")) {
            results[domain.name] = {
              success: false,
              message:
                "Access denied. The user must manually enable access:\n" +
                "1. Open System Settings > Privacy & Security\n" +
                `2. Find the ${domain.name === "mail" ? "Automation" : domain.name.charAt(0).toUpperCase() + domain.name.slice(1)} section\n` +
                "3. Enable access for the terminal application\n" +
                "4. Restart the terminal and try again",
            };
          } else if (msg.includes("not running") && domain.name === "mail") {
            results[domain.name] = {
              success: false,
              message: "Mail.app must be running before authorization can be requested.",
            };
          } else {
            results[domain.name] = { success: false, message: err.message };
          }
        }
      }

      return { results };
    }

    case "config_show": {
      const configArgs = ["config", "show"];
      if (args.profile) configArgs.push("--profile", args.profile);
      return await runCLI("calendar-cli", configArgs);
    }

    case "config_init": {
      const configArgs = ["config", "init"];
      if (args.profile) configArgs.push("--profile", args.profile);
      return await runCLI("calendar-cli", configArgs);
    }

    default:
      throw new Error(`Unknown apple-pim action: ${args.action}`);
  }
}
