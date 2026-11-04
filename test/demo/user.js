// Firefox in the demo: WebGL on the software renderer, no first-run pages, and
// nothing sent anywhere (telemetry, updates, safe browsing, connectivity checks)
user_pref("webgl.force-enabled", true);
user_pref("browser.shell.checkDefaultBrowser", false);
user_pref("browser.aboutwelcome.enabled", false);
user_pref("browser.startup.homepage_override.mstone", "ignore");
user_pref("startup.homepage_welcome_url", "");
user_pref("startup.homepage_welcome_url.additional", "");
user_pref("datareporting.policy.dataSubmissionEnabled", false);
user_pref("datareporting.healthreport.uploadEnabled", false);
user_pref("toolkit.telemetry.enabled", false);
user_pref("toolkit.telemetry.unified", false);
user_pref("app.update.auto", false);
user_pref("app.normandy.enabled", false);
user_pref("extensions.update.enabled", false);
user_pref("browser.safebrowsing.malware.enabled", false);
user_pref("browser.safebrowsing.phishing.enabled", false);
user_pref("browser.safebrowsing.downloads.enabled", false);
user_pref("network.captive-portal-service.enabled", false);
user_pref("network.connectivity-service.enabled", false);
user_pref("browser.newtabpage.activity-stream.feeds.topsites", false);
user_pref("browser.translations.automaticallyPopup", false);
user_pref("browser.tabs.warnOnClose", false);
user_pref("media.autoplay.default", 0);   // the video starts with its sound
// newer Firefox (the Windows runner's) opens on a "Welcome to Firefox" terms-of-use dialog
// over the page, in front of the video and the Aquarium (run 41182102583): skipped
user_pref("termsofuse.bypassNotification", true);
user_pref("datareporting.policy.dataSubmissionPolicyBypassNotification", true);
user_pref("browser.preonboarding.enabled", false);
// Firefox's own "Would you like to pin Firefox to your taskbar? This request is coming
// from Firefox" (Windows 11) sat in front on the Windows runner and kept PowerShell from
// the front, so the freerdp-tk Windows demo was skipped (kit 20261103.10 to 20261104.4,
// seen in windows-host.mp4): no onboarding, upgrade or recommendation messages
user_pref("browser.startup.upgradeDialog.enabled", false);
user_pref("browser.shell.skipDefaultBrowserCheckOnFirstRun", true);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.addons", false);
user_pref("browser.newtabpage.activity-stream.asrouter.userprefs.cfr.features", false);
user_pref("messaging-system.rsexperimentloader.enabled", false);
user_pref("app.shield.optoutstudies.enabled", false);
