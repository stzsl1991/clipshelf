"""Prove changed app bytes retain their signing identity, without trust changes."""
import pathlib
import plistlib
import re
import shutil
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
app = root / "build/拾贴.app"

def signature(path):
    result = subprocess.run(["codesign", "-d", "-r-", "--verbose=4", str(path)], capture_output=True, text=True, check=True)
    output = result.stdout + result.stderr
    requirement = re.search(r'^designated => (.+)$', output, re.M).group(1)
    digest = re.search(r'^CDHash=(.+)$', output, re.M).group(1)
    return requirement, digest

search_list = subprocess.check_output(["security", "list-keychains", "-d", "user"])
original_requirement, original_hash = signature(app)
with tempfile.TemporaryDirectory(prefix="signature-test-", dir=root / "build") as temporary:
    changed = pathlib.Path(temporary) / "Changed.app"
    shutil.copytree(app, changed)
    plist_path = changed / "Contents/Info.plist"
    with plist_path.open("rb") as file:
        plist = plistlib.load(file)
    plist["CFBundleVersion"] = "999"
    with plist_path.open("wb") as file:
        plistlib.dump(plist, file)
    subprocess.run([str(root / "scripts/signing.sh"), str(changed)], cwd=root, check=True)
    new_requirement, new_hash = signature(changed)
    assert original_hash != new_hash, "Fixture did not change the code hash"
    assert original_requirement == new_requirement, "Signing identity changed on rebuild"
    assert "certificate leaf" in original_requirement, "Identity is still tied to an ad-hoc code hash"
assert subprocess.check_output(["security", "list-keychains", "-d", "user"]) == search_list
print("PASS: changed code hash, stable certificate identity, original keychain search list restored.")
