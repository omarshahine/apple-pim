// Mach-O launcher for PIMHelper.app.
//
// Why this exists: macOS refuses to launch an application bundle whose
// CFBundleExecutable is a shell script. LaunchServices rejects it before the
// script ever runs, with:
//
//     _LSOpenURLsWithCompletionHandler() failed for the application
//     ~/Applications/PIMHelper.app with error -10669
//
// -10669 sits in the LaunchServices reserved range whose documented
// neighbours are all "this executable cannot run here" errors
// (kLSExecutableIncorrectFormat = -10661, kLSIncompatibleApplicationVersionErr
// = -10664). It reproduces with a minimal, unsigned, freshly-created bundle
// containing nothing but a two-line zsh script, so it is a property of script
// bundles on current macOS, not of this bundle's contents or signature.
//
// The helper still needs to be a real .app: the whole point is that
// LaunchServices makes the bundle the TCC-responsible process, so Calendar /
// Reminders / Contacts prompts fire against the helper's bundle id instead of
// whatever shell the agent runtime happens to use. So rather than abandon the
// design, this tiny executable becomes CFBundleExecutable and re-execs the
// real dispatcher script from Contents/Resources, forwarding argv verbatim.
// execv replaces this process image, so the script inherits the bundle's
// responsible-process identity exactly as before.

#include <libgen.h>
#include <limits.h>
#include <mach-o/dyld.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#define SCRIPT_RELATIVE_PATH "/../Resources/pim-helper.sh"

int main(int argc, char *argv[]) {
  char executable_path[PATH_MAX];
  uint32_t size = sizeof(executable_path);
  if (_NSGetExecutablePath(executable_path, &size) != 0) {
    fprintf(stderr, "pim-helper: executable path exceeds PATH_MAX\n");
    return 71; // EX_OSERR
  }

  // Resolve symlinks so dirname() yields the real Contents/MacOS directory.
  char resolved_path[PATH_MAX];
  if (realpath(executable_path, resolved_path) == NULL) {
    perror("pim-helper: realpath");
    return 71;
  }

  char script_path[PATH_MAX];
  int written = snprintf(script_path, sizeof(script_path), "%s%s",
                         dirname(resolved_path), SCRIPT_RELATIVE_PATH);
  if (written < 0 || (size_t)written >= sizeof(script_path)) {
    fprintf(stderr, "pim-helper: script path exceeds PATH_MAX\n");
    return 71;
  }

  // argv layout for zsh: ["/bin/zsh", script, <forwarded args...>, NULL].
  char **args = calloc((size_t)argc + 2, sizeof(char *));
  if (args == NULL) {
    perror("pim-helper: calloc");
    return 71;
  }
  args[0] = "/bin/zsh";
  args[1] = script_path;
  for (int i = 1; i < argc; i++) {
    args[i + 1] = argv[i];
  }

  execv("/bin/zsh", args);

  // execv only returns on failure.
  perror("pim-helper: execv");
  free(args);
  return 71;
}
