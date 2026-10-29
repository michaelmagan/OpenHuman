import datetime
import hashlib
import importlib.util
import os
import pathlib
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True

REPO = pathlib.Path(__file__).resolve().parents[3]
RELEASE = REPO / "Tools" / "release"
CHECK = RELEASE / "check-release.sh"
ENTITLEMENTS = REPO / "Apps" / "Mail" / "Entitlements"
TEAM = "ABCDE12345"
OTHER_TEAM = "ZYXWV98765"
BUNDLE_ID = "dev.openhuman.mail"
CONTAINER = "iCloud.dev.openhuman.mail"
GROUP = f"{TEAM}.dev.openhuman.shared"
CERTIFICATE = b"synthetic Developer ID Application certificate"
NOW = datetime.datetime(2026, 10, 16)
SIGNATURE_FAILS = ("ad-hoc signature, not Developer ID", "team not set, expected", "no secure timestamp",
                   "hardened runtime off")
FEED = "https://updates.example.test/appcast.xml"
UPDATE_KEY = "11qYAYKxCrfVS/7TyWQHOg7hcvPapiMlrwIaaPcHURo="
SANDBOX = {"com.apple.security.app-sandbox": True, "com.apple.security.network.client": True}

spec = importlib.util.spec_from_file_location("provisioning", RELEASE / "provisioning.py")
provisioning = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provisioning)

ON_MAC = sys.platform == "darwin" and os.path.exists("/usr/bin/security")
CAN_MAKE_PROFILES = ON_MAC and shutil.which("openssl") is not None
CAN_CODESIGN = ON_MAC and shutil.which("codesign") is not None


def run(args, env=None):
    return subprocess.run([str(a) for a in args], capture_output=True, text=True, env=env, check=False)


def granted(**over):
    entitlements = {
        "com.apple.application-identifier": f"{TEAM}.{BUNDLE_ID}",
        "com.apple.developer.team-identifier": TEAM,
        "com.apple.developer.aps-environment": "production",
        "com.apple.developer.icloud-container-development-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-container-environment": ["Development", "Production"],
        "com.apple.developer.icloud-container-identifiers": [CONTAINER],
        "com.apple.developer.icloud-services": "*",
        "keychain-access-groups": [f"{TEAM}.*"],
    }
    entitlements.update(over)
    return {key: value for key, value in entitlements.items() if value is not None}


def profile(entitlements=None, **over):
    fields = {"AppIDName": "OpenHuman Mail", "ApplicationIdentifierPrefix": [TEAM],
              "CreationDate": datetime.datetime(2026, 10, 16), "DeveloperCertificates": [CERTIFICATE],
              "Entitlements": granted() if entitlements is None else entitlements,
              "ExpirationDate": datetime.datetime(2099, 1, 1), "Name": "Synthetic Developer ID profile",
              "Platform": ["OSX"], "ProvisionsAllDevices": True, "TeamIdentifier": [TEAM],
              "TeamName": "Example Team", "UUID": "00000000-0000-4000-8000-000000000001", "Version": 1}
    fields.update(over)
    return {key: value for key, value in fields.items() if value is not None}


def raw_icloud_entitlements():
    with open(ENTITLEMENTS / "Mail-iCloud.entitlements", "rb") as handle:
        return plistlib.load(handle)


def icloud_entitlements():
    return provisioning.expand(raw_icloud_entitlements(), TEAM, BUNDLE_ID)


def words(script_text, name):
    found = re.findall(rf'^{name}\+?="([^"]*)"', script_text, re.MULTILINE)
    return set(" ".join(found).split())


def make_profile_signer(test_case):
    """A throwaway key wraps fixture profiles in CMS, the container `security cms -D -i` reads."""
    directory = pathlib.Path(tempfile.mkdtemp())
    test_case.addClassCleanup(shutil.rmtree, directory)
    key, cert = directory / "signer-key.pem", directory / "signer.pem"
    made = run(["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-keyout", key, "-out", cert,
                "-days", "1", "-subj", "/CN=Synthetic profile signer"])
    assert made.returncode == 0, made.stderr

    def write(path, fields):
        plain = directory / "profile.plist"
        with open(plain, "wb") as handle:
            plistlib.dump(fields, handle)
        signed = run(["openssl", "smime", "-sign", "-binary", "-nodetach", "-outform", "DER", "-in", plain,
                      "-signer", cert, "-inkey", key, "-out", path])
        assert signed.returncode == 0, signed.stderr
        return path
    return write


class ProfileMatchTests(unittest.TestCase):
    def check(self, fields=None, entitlements=None, certificate=None):
        return provisioning.problems(profile() if fields is None else fields,
                                     icloud_entitlements() if entitlements is None else entitlements,
                                     TEAM, BUNDLE_ID, certificate=certificate, now=NOW)

    def test_the_icloud_entitlements_fit_a_matching_developer_id_profile(self):
        self.assertEqual(self.check(certificate=provisioning.certificate_sha1(CERTIFICATE)), [])

    def test_the_build_variables_are_filled_in_for_the_team_and_bundle_id(self):
        self.assertEqual(icloud_entitlements(), {
            "com.apple.application-identifier": f"{TEAM}.{BUNDLE_ID}",
            "com.apple.developer.team-identifier": TEAM,
            "com.apple.developer.aps-environment": "production",
            "com.apple.developer.icloud-container-environment": "Production",
            "com.apple.developer.icloud-container-identifiers": [CONTAINER],
            "com.apple.developer.icloud-services": ["CloudKit"],
            "keychain-access-groups": [GROUP],
        })

    def test_each_mismatch_is_named_on_its_own(self):
        other_certificate = provisioning.certificate_sha1(b"another certificate")
        cases = {
            "team": (profile(TeamIdentifier=[OTHER_TEAM]), None, f"belongs to team [{OTHER_TEAM}]"),
            "app id": (profile(granted(**{"com.apple.application-identifier": f"{TEAM}.dev.example.other"})), None,
                       f"the profile is for App ID {TEAM}.dev.example.other, but this app is {TEAM}.{BUNDLE_ID}"),
            "wildcard app id": (profile(granted(**{"com.apple.application-identifier": f"{TEAM}.*"})), None,
                                f"the profile is for App ID {TEAM}.*"),
            "container": (profile(granted(**{"com.apple.developer.icloud-container-identifiers":
                                             ["iCloud.dev.example.other"]})), None,
                          "com.apple.developer.icloud-container-identifiers: the app asks for "
                          f"[{CONTAINER}], the profile grants [iCloud.dev.example.other]"),
            "services": (profile(granted(**{"com.apple.developer.icloud-services": ["CloudDocuments"]})), None,
                         "com.apple.developer.icloud-services: the app asks for [CloudKit]"),
            "no iCloud": (profile(granted(**{"com.apple.developer.icloud-services": None})), None,
                          "the profile does not grant com.apple.developer.icloud-services"),
            "keychain group": (profile(granted(**{"keychain-access-groups": [f"{OTHER_TEAM}.*"]})), None,
                               f"keychain-access-groups: the app asks for [{GROUP}], the profile grants "
                               f"[{OTHER_TEAM}.*]"),
            "no keychain groups": (profile(granted(**{"keychain-access-groups": None})), None,
                                   "the profile does not grant keychain-access-groups"),
            "push": (profile(granted(**{"com.apple.developer.aps-environment": "development"})), None,
                     "com.apple.developer.aps-environment: the app asks for production, the profile grants "
                     "development"),
            "no push": (profile(granted(**{"com.apple.developer.aps-environment": None})), None,
                        "the profile does not grant com.apple.developer.aps-environment"),
            "environment": (profile(granted(**{"com.apple.developer.icloud-container-environment":
                                               ["Development"]})), None,
                            "com.apple.developer.icloud-container-environment: the app asks for Production"),
            "expired": (profile(ExpirationDate=datetime.datetime(2026, 10, 15)), None, "expired on 2026-10-15"),
            "development profile": (profile(ProvisionedDevices=["00008103-000000000000001E"]), None,
                                    "it is a development profile"),
            "platform": (profile(Platform=["iOS"]), None, "the profile is for [iOS], not macOS"),
            "certificate": (profile(), other_certificate,
                            f"does not list the signing certificate (SHA-1 {other_certificate})"),
        }
        for name, (fields, certificate, expected) in cases.items():
            with self.subTest(name):
                found = self.check(fields, certificate=certificate)
                self.assertEqual(len(found), 1, found)
                self.assertIn(expected, found[0])

    def test_a_profile_of_another_team_is_refused_for_each_reason(self):
        other = profile(granted(**{"com.apple.application-identifier": f"{OTHER_TEAM}.{BUNDLE_ID}",
                                   "com.apple.developer.team-identifier": OTHER_TEAM,
                                   "keychain-access-groups": [f"{OTHER_TEAM}.*"]}), TeamIdentifier=[OTHER_TEAM])
        found = "\n".join(self.check(other))
        for expected in (f"belongs to team [{OTHER_TEAM}]", f"App ID {OTHER_TEAM}.{BUNDLE_ID}",
                         "com.apple.developer.team-identifier: the app asks for", "keychain-access-groups:"):
            self.assertIn(expected, found)

    def test_wildcards_grant_only_what_they_name(self):
        self.assertTrue(provisioning.grants([f"{TEAM}.*"], [GROUP]))
        self.assertFalse(provisioning.grants([f"{TEAM}.*"], [f"{OTHER_TEAM}.dev.openhuman.shared"]))
        self.assertTrue(provisioning.grants("*", ["CloudKit"]))
        self.assertTrue(provisioning.grants(["CloudKit", "CloudDocuments"], ["CloudKit"]))
        self.assertFalse(provisioning.grants(["CloudDocuments"], ["CloudKit", "CloudDocuments"]))
        self.assertTrue(provisioning.grants(["Development", "Production"], "Production"))
        self.assertFalse(provisioning.grants("production", "development"))
        self.assertTrue(provisioning.grants(True, True))
        self.assertFalse(provisioning.grants(True, "true"))

    def test_an_unknown_build_variable_is_refused(self):
        entitlements = provisioning.expand(dict(raw_icloud_entitlements(),
                                                **{"keychain-access-groups": ["$(OTHER_PREFIX)dev.openhuman.shared"]}),
                                           TEAM, BUNDLE_ID)
        found = self.check(entitlements=entitlements)
        self.assertEqual(found, ["keychain-access-groups keeps the build variable(s) $(OTHER_PREFIX), which this "
                                 "check does not fill in"])

    def test_restricted_entitlements_need_the_identity_entries(self):
        for key in ("com.apple.application-identifier", "com.apple.developer.team-identifier"):
            with self.subTest(key):
                entitlements = icloud_entitlements()
                del entitlements[key]
                self.assertEqual(self.check(entitlements=entitlements),
                                 [f"the entitlements lack {key}, which ties the app to its profile"])

    def test_an_application_identifier_for_another_app_is_refused(self):
        entitlements = dict(icloud_entitlements(), **{"com.apple.application-identifier": f"{TEAM}.dev.example.x"})
        self.assertEqual(self.check(entitlements=entitlements),
                         [f"com.apple.application-identifier is {TEAM}.dev.example.x, but this app is "
                          f"{TEAM}.{BUNDLE_ID}"])

    def test_hardened_runtime_exceptions_are_not_compared_with_the_profile(self):
        entitlements = dict(icloud_entitlements(), **{"com.apple.security.cs.allow-jit": True})
        self.assertEqual(self.check(entitlements=entitlements), [])
        self.assertEqual(self.check(entitlements={"com.apple.security.cs.allow-jit": True}), [])


@unittest.skipUnless(CAN_MAKE_PROFILES, "needs macOS security and openssl")
class ProvisioningCommandTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.write_profile = staticmethod(make_profile_signer(cls))

    def setUp(self):
        self.dir = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir)
        self.out = self.dir / "Mail-iCloud.entitlements"

    def command(self, fields, *extra):
        path = self.write_profile(self.dir / "test.provisionprofile", fields)
        return run([sys.executable, "-B", RELEASE / "provisioning.py", "--profile", path, "--entitlements",
                    ENTITLEMENTS / "Mail-iCloud.entitlements", "--team", TEAM, "--bundle-id", BUNDLE_ID, *extra])

    def test_a_matching_profile_passes_and_the_filled_in_entitlements_are_written(self):
        result = self.command(profile(), "--certificate-sha1", provisioning.certificate_sha1(CERTIFICATE).lower(),
                              "--write", self.out)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(result.stdout, "profile 'Synthetic Developer ID profile' "
                                        "(00000000-0000-4000-8000-000000000001) grants every entitlement: team "
                                        f"{TEAM}, App ID {TEAM}.{BUNDLE_ID}, expires 2099-01-01\n")
        with open(self.out, "rb") as handle:
            self.assertEqual(plistlib.load(handle), icloud_entitlements())

    def test_a_mismatch_exits_1_names_it_and_writes_nothing(self):
        result = self.command(profile(granted(**{"com.apple.developer.aps-environment": "development"})),
                              "--write", self.out)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(result.stdout, "com.apple.developer.aps-environment: the app asks for production, the "
                                        "profile grants development\n")
        self.assertFalse(self.out.exists())

    def test_a_certificate_file_is_compared_by_its_sha1(self):
        certificate = self.dir / "certificate0"
        certificate.write_bytes(CERTIFICATE)
        self.assertEqual(self.command(profile(), "--certificate", certificate).returncode, 0)
        certificate.write_bytes(b"another certificate")
        result = self.command(profile(), "--certificate", certificate)
        self.assertEqual(result.returncode, 1)
        self.assertIn("does not list the signing certificate", result.stdout)

    def test_a_file_that_is_not_a_profile_exits_2(self):
        path = self.dir / "notes.provisionprofile"
        path.write_text("not a profile\n")
        result = run([sys.executable, "-B", RELEASE / "provisioning.py", "--profile", path, "--entitlements",
                      ENTITLEMENTS / "Mail-iCloud.entitlements", "--team", TEAM, "--bundle-id", BUNDLE_ID])
        self.assertEqual(result.returncode, 2)
        self.assertIn("could not decode", result.stderr)

    def test_a_placeholder_team_is_refused(self):
        path = self.write_profile(self.dir / "test.provisionprofile", profile())
        result = run([sys.executable, "-B", RELEASE / "provisioning.py", "--profile", path, "--entitlements",
                      ENTITLEMENTS / "Mail-iCloud.entitlements", "--team", "<TEAMID>", "--bundle-id", BUNDLE_ID])
        self.assertEqual(result.returncode, 2)
        self.assertIn("--team must be a 10-character team id", result.stderr)


@unittest.skipUnless(CAN_CODESIGN and CAN_MAKE_PROFILES, "needs macOS codesign, security and openssl")
class CheckReleaseProfileTests(unittest.TestCase):
    """Synthetic, ad-hoc signed bundles with entitlements and fixture profiles. The signature checks fail an ad-hoc
    app on their own, so each test looks at the other FAIL lines."""

    @classmethod
    def setUpClass(cls):
        cls.write_profile = staticmethod(make_profile_signer(cls))

    def make_app(self, entitlements=None, fields=None, nested=None, sparkle=None, **info):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        app = root / "OpenHuman Mail.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        shutil.copy(shutil.which("true"), app / "Contents" / "MacOS" / "OpenHumanMail")
        plist = {"CFBundleExecutable": "OpenHumanMail", "CFBundleIdentifier": BUNDLE_ID, "CFBundlePackageType": "APPL",
                 "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "1001", "OHGitCommit": "abc1234",
                 "OHReleaseChannel": "early-development", "OHKeychainAccessGroup": GROUP}
        plist.update(info)
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({k: v for k, v in plist.items() if v is not None}, handle)
        if nested is not None:
            (app / "Contents" / "Helpers").mkdir()
            helper = app / "Contents" / "Helpers" / "helper"
            shutil.copy(shutil.which("true"), helper)
            self.sign(helper, nested, root / "helper.plist")
        if sparkle is not None:
            self.make_sparkle(app, root, with_services=sparkle == "services")
        if fields is not None:
            self.write_profile(app / "Contents" / "embedded.provisionprofile", fields)
        self.sign(app, entitlements, root / "app.plist")
        return app

    def make_sparkle(self, app, root, with_services):
        """A minimal Sparkle.framework, signed inside out; with_services adds Downloader.xpc in its own sandbox."""
        framework = app / "Contents" / "Frameworks" / "Sparkle.framework"
        version = framework / "Versions" / "B"
        (version / "Resources").mkdir(parents=True)
        shutil.copy(shutil.which("true"), version / "Sparkle")
        with open(version / "Resources" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleExecutable": "Sparkle", "CFBundleIdentifier": "org.sparkle-project.Sparkle",
                           "CFBundlePackageType": "FMWK"}, handle)
        (framework / "Versions" / "Current").symlink_to("B")
        names = ["Sparkle", "Resources"]
        if with_services:
            xpc = version / "XPCServices" / "Downloader.xpc" / "Contents"
            (xpc / "MacOS").mkdir(parents=True)
            shutil.copy(shutil.which("true"), xpc / "MacOS" / "Downloader")
            with open(xpc / "Info.plist", "wb") as handle:
                plistlib.dump({"CFBundleExecutable": "Downloader", "CFBundlePackageType": "XPC!",
                               "CFBundleIdentifier": "org.sparkle-project.DownloaderService"}, handle)
            self.sign(xpc.parent, SANDBOX, root / "downloader.plist")
            names.append("XPCServices")
        for name in names:
            (framework / name).symlink_to(f"Versions/Current/{name}")
        self.sign(framework, None, root / "framework.plist")

    def sign(self, path, entitlements, plist):
        args = ["codesign", "--force", "--sign", "-"]
        if entitlements is not None:
            with open(plist, "wb") as handle:
                plistlib.dump(entitlements, handle)
            args += ["--entitlements", plist]
        signed = run([*args, path])
        self.assertEqual(signed.returncode, 0, signed.stderr)

    def check(self, *args):
        result = run([CHECK, *args])
        fails = [line.strip()[len("FAIL  "):] for line in result.stdout.splitlines() if line.startswith("  FAIL  ")]
        return result, [line for line in fails if not any(text in line for text in SIGNATURE_FAILS)]

    def test_icloud_entitlements_with_a_matching_embedded_profile_pass(self):
        app = self.make_app(icloud_entitlements(), profile())
        result, fails = self.check("--pre-notarization", "--icloud", "--team", TEAM, app)
        self.assertEqual(fails, [], result.stdout)
        self.assertIn("ok    app: entitlement keychain-access-groups (allowed)", result.stdout)
        self.assertIn("ok    app: embedded profile 'Synthetic Developer ID profile'", result.stdout)
        self.assertIn(f"ok    app: Info.plist OHKeychainAccessGroup {GROUP} is granted by the signature", result.stdout)
        self.assertIn("signing certificate not compared with the profile (the signature has none)", result.stdout)

    def test_icloud_entitlements_without_an_embedded_profile_fail(self):
        result, fails = self.check("--pre-notarization", "--team", TEAM, self.make_app(icloud_entitlements()))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(fails), 1, fails)
        self.assertIn("which need a provisioning profile, but Contents/embedded.provisionprofile is missing", fails[0])
        self.assertIn("keychain-access-groups", fails[0])

    def test_a_profile_that_does_not_grant_the_container_fails(self):
        fields = profile(granted(**{"com.apple.developer.icloud-container-identifiers": ["iCloud.dev.example.x"]}))
        result, fails = self.check("--pre-notarization", "--team", TEAM, self.make_app(icloud_entitlements(), fields))
        self.assertEqual(fails, ["app: provisioning profile: com.apple.developer.icloud-container-identifiers: the "
                                 f"app asks for [{CONTAINER}], the profile grants [iCloud.dev.example.x]"])

    def test_an_expired_profile_fails(self):
        fields = profile(ExpirationDate=datetime.datetime(2001, 1, 1))
        result, fails = self.check("--pre-notarization", "--team", TEAM, self.make_app(icloud_entitlements(), fields))
        self.assertEqual(fails, ["app: provisioning profile: the profile expired on 2001-01-01. Download a new one"])

    def test_an_unsigned_build_cannot_carry_icloud_entitlements(self):
        result, fails = self.check("--unsigned", self.make_app(icloud_entitlements()))
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(fails), 1, fails)
        self.assertIn("An ad-hoc signed app cannot have one", fails[0])

    def test_an_entitlement_outside_the_allowed_list_fails(self):
        for key, value in (("com.apple.security.cs.disable-library-validation", True),
                           ("com.apple.security.get-task-allow", True)):
            with self.subTest(key):
                result, fails = self.check("--unsigned", self.make_app({key: value}))
                self.assertEqual(result.returncode, 1)
                self.assertEqual(len(fails), 1, fails)
                self.assertIn(key, fails[0])
        result, fails = self.check("--pre-notarization", "--team", TEAM, self.make_app(
            dict(icloud_entitlements(), **{"com.apple.developer.ubiquity-kvstore-identifier": f"{TEAM}.x"}),
            profile()))
        self.assertIn("app: entitlement com.apple.developer.ubiquity-kvstore-identifier is broader than this app needs "
                      f"(ALLOWED_ENTITLEMENTS in {CHECK})", fails)

    def test_icloud_requires_every_icloud_entitlement_and_the_profile(self):
        result, fails = self.check("--pre-notarization", "--icloud", "--team", TEAM, self.make_app())
        self.assertEqual(result.returncode, 1)
        for key in ("com.apple.developer.aps-environment", "com.apple.developer.icloud-container-environment",
                    "com.apple.developer.icloud-container-identifiers", "com.apple.developer.icloud-services",
                    "keychain-access-groups", "com.apple.application-identifier",
                    "com.apple.developer.team-identifier"):
            self.assertIn(f"app: built for iCloud, but the signature lacks {key}", fails)
        self.assertIn("app: built for iCloud, but Contents/embedded.provisionprofile is missing", fails)
        self.assertEqual(len(fails), 8, fails)

    def test_a_keychain_group_the_signature_does_not_grant_fails(self):
        app = self.make_app(icloud_entitlements(), profile(), OHKeychainAccessGroup="dev.openhuman.shared")
        result, fails = self.check("--pre-notarization", "--team", TEAM, app)
        self.assertEqual(len(fails), 1, fails)
        self.assertIn("app: Info.plist OHKeychainAccessGroup is 'dev.openhuman.shared'", fails[0])

    def test_nested_code_may_not_carry_icloud_entitlements(self):
        result, fails = self.check("--unsigned", self.make_app(nested={"keychain-access-groups": [GROUP]}))
        self.assertEqual(fails, ["Contents/Helpers/helper: entitlement keychain-access-groups needs a provisioning "
                                 "profile; only the app itself may carry it"])

    def test_a_profile_no_entitlement_needs_only_warns(self):
        result, fails = self.check("--unsigned", self.make_app(fields=profile()))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("warn  app: embeds a provisioning profile that no entitlement needs", result.stdout)

    def test_unsigned_and_icloud_do_not_go_together(self):
        self.assertEqual(run([CHECK, "--unsigned", "--icloud", self.make_app()]).returncode, 2)

    def test_an_app_without_a_feed_never_updates(self):
        result, fails = self.check("--unsigned", "--updates", "off", self.make_app(sparkle="plain"))
        self.assertEqual(fails, [], result.stdout)
        self.assertIn("ok    Sparkle.framework without XPC services", result.stdout)
        self.assertIn("ok    updates off: no SUFeedURL or SUPublicEDKey", result.stdout)

    def test_sparkles_xpc_services_never_ship_and_their_entitlements_stay_refused(self):
        result, fails = self.check("--unsigned", self.make_app(sparkle="services"))
        self.assertEqual(result.returncode, 1)
        self.assertTrue(any(line.startswith("Sparkle's XPC services are in the app (Contents/Frameworks/Sparkle.framework/"
                                            "Versions/B/XPCServices/Downloader.xpc") for line in fails), fails)
        downloader = [line for line in fails if "Downloader.xpc/Contents/MacOS/Downloader: entitlement" in line]
        self.assertEqual(len(downloader), 2, fails)
        self.assertTrue(all("is broader than this app needs" in line for line in downloader), downloader)

    def test_the_xpc_services_cannot_be_switched_on(self):
        for flag in ("SUEnableDownloaderService", "SUEnableInstallerLauncherService"):
            with self.subTest(flag):
                result, fails = self.check("--unsigned", self.make_app(sparkle="plain", **{flag: True}))
                self.assertEqual(fails, [f"Info.plist turns on {flag}, which needs the XPC services a non-sandboxed "
                                         "app leaves out"])

    def test_only_a_developer_id_build_without_icloud_carries_a_feed(self):
        feed = dict(SUFeedURL=FEED, SUPublicEDKey=UPDATE_KEY)
        result, fails = self.check("--unsigned", self.make_app(sparkle="plain", **feed))
        self.assertEqual(fails, ["an unsigned build carries an update feed; only Developer ID builds may update"])
        result, fails = self.check("--pre-notarization", "--team", TEAM, self.make_app(sparkle="plain", **feed))
        self.assertEqual(fails, [], result.stdout)
        self.assertIn(f"ok    update feed {FEED}", result.stdout)
        result, fails = self.check("--pre-notarization", "--team", TEAM,
                                   self.make_app(icloud_entitlements(), profile(), sparkle="plain", **feed))
        self.assertEqual(len(fails), 1, fails)
        self.assertIn("Updating builds are made with --no-icloud", fails[0])
        result, fails = self.check("--pre-notarization", "--team", TEAM, self.make_app(**feed))
        self.assertEqual(fails, ["Info.plist names an update feed, but the app has no Sparkle.framework"])

    def test_the_feed_and_key_are_the_ones_the_build_asked_for(self):
        app = self.make_app(sparkle="plain", SUFeedURL=FEED, SUPublicEDKey=UPDATE_KEY)
        result, fails = self.check("--pre-notarization", "--team", TEAM, "--updates", FEED, "--update-key", UPDATE_KEY, app)
        self.assertEqual(fails, [], result.stdout)
        result, fails = self.check("--pre-notarization", "--team", TEAM, "--updates", "off", app)
        self.assertEqual(len(fails), 1, fails)
        self.assertIn("but this build was made without --enable-updates", fails[0])
        other = "https://other.example.test/appcast.xml"
        result, fails = self.check("--pre-notarization", "--team", TEAM, "--updates", other, app)
        self.assertEqual(fails, [f"Info.plist SUFeedURL is '{FEED}', expected {other}"])
        result, fails = self.check("--pre-notarization", "--team", TEAM, "--updates", FEED, self.make_app(sparkle="plain"))
        self.assertEqual(fails, ["built with --enable-updates, but Info.plist has no SUFeedURL or SUPublicEDKey"])
        for key in ("", "not a key", "AAAA"):
            with self.subTest(key=key):
                result, fails = self.check("--pre-notarization", "--team", TEAM,
                                           self.make_app(sparkle="plain", SUFeedURL=FEED, SUPublicEDKey=key))
                self.assertTrue(any("not a base64 EdDSA public key of 32 bytes" in line for line in fails), fails)

    def test_a_feed_on_this_mac_is_only_for_a_staged_test(self):
        app = self.make_app(sparkle="plain", SUFeedURL="http://127.0.0.1:8000/appcast.xml", SUPublicEDKey=UPDATE_KEY)
        result, fails = self.check("--pre-notarization", "--team", TEAM, app)
        self.assertEqual(fails, [], result.stdout)
        self.assertIn("warn  update feed http://127.0.0.1:8000/appcast.xml is on this Mac: a staged update test only",
                      result.stdout)
        result, fails = self.check("--team", TEAM, app)
        self.assertIn("update feed http://127.0.0.1:8000/appcast.xml is on this Mac; a notarized build must read an "
                      "https:// feed", fails)
        result, fails = self.check("--pre-notarization", "--team", TEAM,
                                   self.make_app(sparkle="plain", SUFeedURL="http://updates.example.test/appcast.xml",
                                                 SUPublicEDKey=UPDATE_KEY))
        self.assertEqual(fails, ["update feed 'http://updates.example.test/appcast.xml' is not https://"])

    def test_update_options_that_cannot_apply_are_refused(self):
        app = self.make_app()
        for args in (["--update-key", UPDATE_KEY], ["--updates", "off", "--update-key", UPDATE_KEY],
                     ["--unsigned", "--updates", FEED], ["--icloud", "--updates", FEED], ["--updates"]):
            with self.subTest(args):
                self.assertEqual(run([CHECK, *args, app]).returncode, 2)


class EntitlementFilesTests(unittest.TestCase):
    def test_the_default_entitlements_are_empty(self):
        with open(ENTITLEMENTS / "Mail.entitlements", "rb") as handle:
            self.assertEqual(plistlib.load(handle), {})

    def test_xcode_builds_take_oh_entitlements_which_defaults_to_the_empty_file(self):
        base = (REPO / "Apps" / "Mail" / "Config" / "Base.xcconfig").read_text(encoding="utf-8")
        self.assertRegex(base, r"(?m)^OH_ENTITLEMENTS = Entitlements/Mail\.entitlements$")
        project = (REPO / "Apps" / "Mail" / "project.yml").read_text(encoding="utf-8")
        self.assertIn("CODE_SIGN_ENTITLEMENTS: $(OH_ENTITLEMENTS)", project)
        self.assertNotRegex(project, r"(?m)^\s+entitlements:")

    def test_the_icloud_file_asks_for_exactly_the_keys_the_release_check_allows(self):
        script = CHECK.read_text(encoding="utf-8")
        allowed = words(script, "ICLOUD_ENTITLEMENTS") | words(script, "IDENTITY_ENTITLEMENTS")
        self.assertEqual(set(raw_icloud_entitlements()), allowed)

    def test_the_icloud_keychain_group_is_the_one_the_app_reads(self):
        project = (REPO / "Apps" / "Mail" / "project.yml").read_text(encoding="utf-8")
        configured = re.search(r"OHKeychainAccessGroup: (\S+)", project).group(1)
        swift = (REPO / "Packages" / "OpenHumanGmail" / "Sources" / "OpenHumanGmailApple" /
                 "KeychainSharing.swift").read_text(encoding="utf-8")
        name = re.search(r'groupName = "([^"]+)"', swift).group(1)
        self.assertEqual(raw_icloud_entitlements()["keychain-access-groups"], [configured])
        self.assertEqual(configured, "$(AppIdentifierPrefix)" + name)

    @unittest.skipUnless(CAN_CODESIGN, "needs macOS codesign")
    def test_the_release_check_keeps_the_default_file_empty_and_the_icloud_file_allowed(self):
        root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, root)
        (root / "Tools" / "release").mkdir(parents=True)
        for name in ("check-release.sh", "provisioning.py"):
            shutil.copy2(RELEASE / name, root / "Tools" / "release" / name)
        (root / "Apps" / "Mail" / "Entitlements").mkdir(parents=True)
        with open(root / "Apps" / "Mail" / "Entitlements" / "Mail.entitlements", "wb") as handle:
            plistlib.dump({"keychain-access-groups": [GROUP]}, handle)
        with open(root / "Apps" / "Mail" / "Entitlements" / "Mail-iCloud.entitlements", "wb") as handle:
            plistlib.dump(dict(raw_icloud_entitlements(), **{"com.apple.developer.ubiquity-kvstore-identifier": "x"}),
                          handle)
        app = root / "Synthetic.app"
        (app / "Contents" / "MacOS").mkdir(parents=True)
        shutil.copy(shutil.which("true"), app / "Contents" / "MacOS" / "Synthetic")
        with open(app / "Contents" / "Info.plist", "wb") as handle:
            plistlib.dump({"CFBundleExecutable": "Synthetic", "CFBundleIdentifier": "dev.example.synthetic",
                           "CFBundlePackageType": "APPL", "OHGitCommit": "abc1234",
                           "OHReleaseChannel": "early-development"}, handle)
        self.assertEqual(run(["codesign", "--force", "--sign", "-", app]).returncode, 0)
        result = run([root / "Tools" / "release" / "check-release.sh", "--unsigned", app])
        self.assertEqual(result.returncode, 1)
        fails = [line for line in result.stdout.splitlines() if line.startswith("  FAIL  ")]
        self.assertEqual(len(fails), 2, result.stdout)
        self.assertIn("Mail.entitlements asks for keychain-access-groups. It must stay empty", fails[0])
        self.assertIn("Mail-iCloud.entitlements asks for com.apple.developer.ubiquity-kvstore-identifier, which "
                      "ALLOWED_ENTITLEMENTS", fails[1])


FAKE_SECURITY = """#!/bin/sh
printf 'security %s\\n' "$*" >> "$FAKE_LOG"
if [ "$1" = find-identity ]; then
    printf '  1) %s "Developer ID Application: Example Person (ABCDE12345)"\\n     1 valid identities found\\n' \\
        "$FAKE_IDENTITY"
    exit 0
fi
exec /usr/bin/security "$@"
"""

REFUSE = """#!/bin/sh
printf '%s %s\\n' "$(basename "$0")" "$*" >> "$FAKE_LOG"
exit 1
"""


@unittest.skipUnless(CAN_MAKE_PROFILES, "needs macOS security and openssl")
class MakeDmgProfileTests(unittest.TestCase):
    """A throwaway Git repository with copies of the release scripts. Stand-ins on PATH answer `security
    find-identity` with an invented Developer ID identity and refuse every build, sign or notary tool, so nothing is
    built and nothing reaches Apple."""

    @classmethod
    def setUpClass(cls):
        cls.write_profile = staticmethod(make_profile_signer(cls))

    def setUp(self):
        self.root = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.root)
        (self.root / "Tools" / "release").mkdir(parents=True)
        for name in ("make-dmg.sh", "bump-version.sh", "check-release.sh", "provisioning.py", "ExportOptions.plist"):
            shutil.copy2(RELEASE / name, self.root / "Tools" / "release" / name)
        (self.root / "Apps" / "Mail" / "Config").mkdir(parents=True)
        (self.root / "Apps" / "Mail" / "Config" / "Version.xcconfig").write_text(
            "MARKETING_VERSION = 0.1.0\nOH_RELEASE_CHANNEL = early-development\n")
        shutil.copytree(ENTITLEMENTS, self.root / "Apps" / "Mail" / "Entitlements")
        (self.root / ".gitignore").write_text("build/\n")
        self.bin = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.bin)
        (self.bin / "security").write_text(FAKE_SECURITY)
        for tool in ("xcodebuild", "xcrun", "hdiutil", "codesign"):
            (self.bin / tool).write_text(REFUSE)
        for tool in self.bin.iterdir():
            tool.chmod(0o755)
        self.log = self.bin / "calls"
        self.env = dict(os.environ, PATH=f"{self.bin}{os.pathsep}{os.environ['PATH']}", FAKE_LOG=str(self.log),
                        FAKE_IDENTITY=provisioning.certificate_sha1(CERTIFICATE), GIT_CONFIG_GLOBAL=os.devnull,
                        GIT_CONFIG_NOSYSTEM="1", OH_RELEASE_ENV=os.devnull)
        for name in ("OH_PROVISIONING_PROFILE", "OH_SIGN_IDENTITY", "OH_NOTARY_PROFILE", "OH_BUNDLE_ID_PREFIX",
                     "OH_SIGNING_KEYCHAIN", "OH_SIGNING_KEYCHAIN_PASSWORD_FILE", "OH_UPDATE_FEED_URL",
                     "OH_SPARKLE_PUBLIC_KEY"):
            self.env.pop(name, None)
        for args in (["init", "-q"], ["add", "-A"],
                     ["-c", "user.name=Test", "-c", "user.email=test@example.com", "commit", "-q", "-m", "fixture"]):
            subprocess.run(["git", "-C", str(self.root), *args], env=self.env, capture_output=True, check=True)
        self.profiles = pathlib.Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.profiles)

    def make_dmg(self, *args, fields=None, profile_path=None, updates=None):
        env = dict(self.env)
        if updates is not None:
            env.update(updates)
        if fields is not None:
            profile_path = self.write_profile(self.profiles / "Mail.provisionprofile", fields)
        if profile_path is not None:
            env["OH_PROVISIONING_PROFILE"] = str(profile_path)
        return run([self.root / "Tools" / "release" / "make-dmg.sh", "--build-number", "7", *args], env=env)

    def tool_calls(self):
        calls = self.log.read_text().splitlines() if self.log.exists() else []
        return [call for call in calls if not call.startswith("security ")]

    def line(self, result, text):
        return next(line for line in result.stdout.splitlines() if text in line)

    def test_a_dry_run_without_a_profile_prints_the_icloud_signing_with_a_placeholder(self):
        result = self.make_dmg("--dry-run")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("OH_PROVISIONING_PROFILE is not set; the dry run uses a placeholder. A real run stops here.",
                      result.stdout)
        self.assertIn("OH_ENTITLEMENTS=Entitlements/Mail.entitlements", self.line(result, "xcodebuild archive"))
        self.assertIn("--write", self.line(result, "provisioning.py"))
        self.assertIn("$ cp \\<your-Developer-ID.provisionprofile\\> ", self.line(result, "embedded.provisionprofile"))
        sign = next(line for line in result.stdout.splitlines() if "codesign --force" in line and "--entitlements" in line)
        for part in ("--options runtime --timestamp --entitlements", "Mail-iCloud.entitlements"):
            self.assertIn(part, sign)
        self.assertIn("--icloud", self.line(result, "check-release.sh --team"))
        self.assertEqual(self.tool_calls(), [])

    def test_a_dry_run_compares_the_profile_it_is_given(self):
        result = self.make_dmg("--dry-run", fields=profile())
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn(f"make-dmg: profile 'Synthetic Developer ID profile' (00000000-0000-4000-8000-000000000001) "
                      f"grants every entitlement: team {TEAM}, App ID {TEAM}.{BUNDLE_ID}", result.stdout)
        self.assertIn(str(self.profiles / "Mail.provisionprofile"), self.line(result, "embedded.provisionprofile"))

    def test_a_real_run_without_a_profile_stops_before_building(self):
        result = self.make_dmg("--sign-only")
        self.assertEqual(result.returncode, 1)
        self.assertIn("set OH_PROVISIONING_PROFILE", result.stderr)
        self.assertIn("--no-icloud", result.stderr)
        self.assertEqual(self.tool_calls(), [])
        self.assertFalse((self.root / "build").exists())

    def test_a_real_run_with_a_missing_profile_file_stops_before_building(self):
        result = self.make_dmg("--sign-only", profile_path=self.profiles / "missing.provisionprofile")
        self.assertEqual(result.returncode, 1)
        self.assertIn("which is not a file", result.stderr)
        self.assertEqual(self.tool_calls(), [])

    def test_a_real_run_with_a_profile_that_does_not_fit_stops_before_building(self):
        cases = {
            "push": (profile(granted(**{"com.apple.developer.aps-environment": "development"})),
                     "com.apple.developer.aps-environment: the app asks for production, the profile grants development"),
            "container": (profile(granted(**{"com.apple.developer.icloud-container-identifiers": ["iCloud.x"]})),
                          "com.apple.developer.icloud-container-identifiers: the app asks for"),
            "certificate": (profile(DeveloperCertificates=[b"another certificate"]),
                            "does not list the signing certificate"),
            "app id": (profile(granted(**{"com.apple.application-identifier": f"{TEAM}.dev.example.other"})),
                       f"the profile is for App ID {TEAM}.dev.example.other"),
        }
        for name, (fields, expected) in cases.items():
            with self.subTest(name):
                result = self.make_dmg("--sign-only", fields=fields)
                self.assertEqual(result.returncode, 1)
                self.assertIn(expected, result.stderr)
                self.assertIn("Nothing was built", result.stderr)
                self.assertEqual(self.tool_calls(), [])
                self.assertFalse((self.root / "build").exists())

    def test_no_icloud_and_unsigned_builds_need_no_profile(self):
        for args in (["--no-icloud"], ["--unsigned"], ["--unsigned", "--no-icloud"]):
            with self.subTest(args):
                result = self.make_dmg("--dry-run", *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("Provisioning profile", result.stdout)
                self.assertNotIn("embedded.provisionprofile", result.stdout)
                self.assertNotIn("Mail-iCloud.entitlements", result.stdout)
                self.assertNotIn("--icloud", self.line(result, "check-release.sh --"))
                self.assertIn("OH_ENTITLEMENTS=Entitlements/Mail.entitlements",
                              self.line(result, "xcodebuild archive"))
                self.assertEqual(self.tool_calls(), [])

    def test_every_build_leaves_sparkles_xpc_services_out_and_signs_sparkle_again(self):
        for args, signing in ((["--no-icloud"], "--options runtime --timestamp"), (["--unsigned"], "--sign -")):
            with self.subTest(args):
                result = self.make_dmg("--dry-run", *args)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                removed = self.line(result, "XPCServices")
                self.assertIn("rm -rf", removed)
                self.assertIn("Sparkle.framework/Versions/B/XPCServices", removed)
                for part in ("Versions/B/Autoupdate", "Versions/B/Updater.app"):
                    self.assertIn(signing, self.line(result, part))
                self.assertIn("updates off", result.stdout)

    def test_updates_need_a_developer_id_build_without_icloud(self):
        for args, expected in ((["--enable-updates"], "--no-icloud"),
                               (["--enable-updates", "--unsigned", "--no-icloud"], "Developer ID")):
            with self.subTest(args):
                result = self.make_dmg("--dry-run", *args, updates={"OH_UPDATE_FEED_URL": FEED,
                                                                    "OH_SPARKLE_PUBLIC_KEY": UPDATE_KEY})
                self.assertEqual(result.returncode, 2)
                self.assertIn(expected, result.stderr)
                self.assertEqual(self.tool_calls(), [])

    def test_a_real_run_with_updates_needs_the_feed_and_key_before_building(self):
        result = self.make_dmg("--sign-only", "--no-icloud", "--enable-updates", updates={})
        self.assertEqual(result.returncode, 1)
        self.assertIn("--enable-updates needs OH_UPDATE_FEED_URL", result.stderr)
        self.assertEqual(self.tool_calls(), [])
        self.assertFalse((self.root / "build").exists())

    def test_a_dry_run_with_updates_builds_in_the_feed_and_key(self):
        result = self.make_dmg("--dry-run", "--no-icloud", "--enable-updates",
                               updates={"OH_UPDATE_FEED_URL": FEED, "OH_SPARKLE_PUBLIC_KEY": UPDATE_KEY})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = self.line(result, "xcodebuild archive")
        self.assertIn(f" OH_UPDATE_FEED_URL={FEED} ", archive)
        self.assertIn(f" OH_SPARKLE_PUBLIC_KEY={UPDATE_KEY} ", archive)
        self.assertIn(f"--updates {FEED} --update-key {UPDATE_KEY}", self.line(result, "check-release.sh --"))
        self.assertEqual(self.tool_calls(), [])

    def test_without_enable_updates_a_set_feed_never_reaches_the_app(self):
        result = self.make_dmg("--dry-run", "--no-icloud",
                               updates={"OH_UPDATE_FEED_URL": FEED, "OH_SPARKLE_PUBLIC_KEY": UPDATE_KEY})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        archive = self.line(result, "xcodebuild archive")
        self.assertIn(" OH_UPDATE_FEED_URL= OH_SPARKLE_PUBLIC_KEY= ", archive)
        self.assertNotIn(FEED, result.stdout)
        self.assertIn("--updates off", self.line(result, "check-release.sh --"))

    def test_update_settings_are_checked_before_building(self):
        cases = (
            (["--no-icloud"], {"OH_UPDATE_FEED_URL": "http://updates.example.test/appcast.xml"}, "must start with https://"),
            (["--no-icloud"], {"OH_SPARKLE_PUBLIC_KEY": "not a key"}, "not a base64 EdDSA public key"),
            (["--no-icloud"], {"OH_UPDATE_FEED_URL": "http://127.0.0.1:8000/appcast.xml"}, "add --sign-only"),
        )
        for args, override, expected in cases:
            with self.subTest(expected):
                settings = dict({"OH_UPDATE_FEED_URL": FEED, "OH_SPARKLE_PUBLIC_KEY": UPDATE_KEY}, **override)
                result = self.make_dmg("--dry-run", "--enable-updates", *args, updates=settings)
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn(expected, result.stderr)
                self.assertIn("Nothing was built", result.stderr)
        result = self.make_dmg("--dry-run", "--sign-only", "--no-icloud", "--enable-updates",
                               updates={"OH_UPDATE_FEED_URL": "http://127.0.0.1:8000/appcast.xml",
                                        "OH_SPARKLE_PUBLIC_KEY": UPDATE_KEY})
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)


if __name__ == "__main__":
    unittest.main()
