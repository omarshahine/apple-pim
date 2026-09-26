"""Permission-free subprocess verification of the upstream loader patch."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = ROOT / 'swift/Sources/PIMConfig'
with tempfile.TemporaryDirectory(prefix='pim-loader-check-') as temporary:
    work = Path(temporary)
    main = work / 'main.swift'
    main.write_text('''import Foundation
if CommandLine.arguments.count > 1 && CommandLine.arguments[1] == "fixture" {
    let restricted = PIMConfiguration(mail: DomainConfig(enabled: false))
    let data = try JSONEncoder().encode(restricted)
    FileHandle.standardOutput.write(data)
} else {
    let config = ConfigLoader.load()
    print(config.mail.enabled ? "mail-enabled" : "mail-disabled")
}
''')
    binary = work / 'loader'
    subprocess.run(['swiftc', str(SOURCE / 'PIMConfiguration.swift'), str(SOURCE / 'PIMProfileOverride.swift'), str(SOURCE / 'ConfigLoader.swift'), str(main), '-o', str(binary)], check=True)
    env = {k:v for k,v in os.environ.items() if not k.startswith('APPLE_PIM_')}
    configdir = work / 'config'
    configdir.mkdir()
    env['APPLE_PIM_CONFIG_DIR'] = str(configdir)
    config = configdir / 'config.json'
    def check(label, expected, output=None):
        run = subprocess.run([str(binary)], env=env, capture_output=True, text=True)
        assert run.returncode == expected, (label, run.returncode, run.stderr)
        if output:
            assert output in run.stdout, (label, run.stdout)
        if expected:
            assert not run.stdout, (label, 'unexpected successful output')
        print('PASS', label)
    check('missing base retains defaults', 0, 'mail-enabled')
    config.write_text('{')
    check('malformed base exits nonzero', 1)
    config.unlink()
    config.mkdir()
    check('unreadable base exits nonzero', 1)
    config.rmdir()
    fixture = subprocess.check_output([str(binary), 'fixture'], env=env)
    config.write_bytes(fixture)
    check('valid base preserves restrictions', 0, 'mail-disabled')
    env['APPLE_PIM_PROFILE'] = 'missing'
    check('missing explicit profile exits nonzero', 1)
    profiles = configdir / 'profiles'
    profiles.mkdir()
    (profiles / 'missing.json').write_text('{')
    check('malformed explicit profile exits nonzero', 1)
    (profiles / 'missing.json').write_text('{}')
    check('empty profile retains base restrictions', 0, 'mail-disabled')
print('7 subprocess cases passed; no PIM permissions or user data accessed')
