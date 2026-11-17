// Test-only driver against the public Sparkle 2.10 API. No private headers,
// no production trust, no replacement implementation. Sparkle installs itself.
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <Sparkle/Sparkle.h>

@interface LabDriver : NSObject <SPUUserDriver, SPUUpdaterDelegate>
@end

@implementation LabDriver
- (void)showUpdatePermissionRequest:(SPUUpdatePermissionRequest *)request reply:(void (^)(SUUpdatePermissionResponse *))reply {
    reply([[SUUpdatePermissionResponse alloc] initWithAutomaticUpdateChecks:NO sendSystemProfile:NO]);
}
- (void)showUserInitiatedUpdateCheckWithCancellation:(void (^)(void))cancellation {
    fprintf(stderr, "LAB: checking feed\n");
}
- (void)showUpdateFoundWithAppcastItem:(SUAppcastItem *)item state:(SPUUserUpdateState *)state reply:(void (^)(SPUUserUpdateChoice))reply {
    fprintf(stderr, "LAB: found version %s\n", item.displayVersionString.UTF8String);
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showUpdateReleaseNotesWithDownloadData:(SPUDownloadData *)data {}
- (void)showUpdateReleaseNotesFailedToDownloadWithError:(NSError *)error {}
- (void)showUpdateNotFoundWithError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    fprintf(stderr, "LAB: no update: %s\n", error.localizedDescription.UTF8String);
    acknowledgement();
    exit(11);
}
- (void)showUpdaterError:(NSError *)error acknowledgement:(void (^)(void))acknowledgement {
    fprintf(stderr, "LAB: updater error %s:%ld: %s\n", error.domain.UTF8String, (long)error.code, error.localizedDescription.UTF8String);
    for (NSError *underlying = error.userInfo[NSUnderlyingErrorKey]; underlying != nil; underlying = underlying.userInfo[NSUnderlyingErrorKey]) {
        fprintf(stderr, "LAB: underlying %s:%ld: %s\n", underlying.domain.UTF8String, (long)underlying.code, underlying.localizedDescription.UTF8String);
    }
    acknowledgement();
    exit(12);
}
- (void)showDownloadInitiatedWithCancellation:(void (^)(void))cancellation {
    fprintf(stderr, "LAB: downloading\n");
}
- (void)showDownloadDidReceiveExpectedContentLength:(uint64_t)length {}
- (void)showDownloadDidReceiveDataOfLength:(uint64_t)length {}
- (void)showDownloadDidStartExtractingUpdate { fprintf(stderr, "LAB: extracting\n"); }
- (void)showExtractionReceivedProgress:(double)progress {}
- (void)showReadyToInstallAndRelaunch:(void (^)(SPUUserUpdateChoice))reply {
    fprintf(stderr, "LAB: installing\n");
    reply(SPUUserUpdateChoiceInstall);
}
- (void)showInstallingUpdateWithApplicationTerminated:(BOOL)terminated retryTerminatingApplication:(void (^)(void))retry {
    fprintf(stderr, "LAB: waiting for installer (terminated=%d)\n", terminated);
}
- (void)showUpdateInstalledAndRelaunched:(BOOL)relaunched acknowledgement:(void (^)(void))acknowledgement {
    fprintf(stderr, "LAB: Sparkle reported installation completed\n");
    acknowledgement();
    exit(0);
}
- (void)dismissUpdateInstallation {}
- (BOOL)updater:(SPUUpdater *)updater shouldProceedWithUpdate:(SUAppcastItem *)item updateCheck:(SPUUpdateCheck)check error:(NSError **)error {
    // Fail closed: only the exact lab version and locally served archive.
    NSURL *url = item.fileURL;
    if ([item.displayVersionString isEqualToString:@"0.16.1"] &&
        [url.scheme isEqualToString:@"http"] && [url.host isEqualToString:@"127.0.0.1"] &&
        [url.path isEqualToString:@"/update.zip"]) return YES;
    if (error != NULL) *error = [NSError errorWithDomain:@"MacSync.CI" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unexpected laboratory asset"}];
    return NO;
}
- (BOOL)updater:(SPUUpdater *)updater shouldDownloadReleaseNotesForUpdate:(SUAppcastItem *)item { return NO; }
- (BOOL)updaterShouldRelaunchApplication:(SPUUpdater *)updater { return NO; }
- (void)updater:(SPUUpdater *)updater didFinishUpdateCycleForUpdateCheck:(SPUUpdateCheck)check error:(NSError *)error {
    if (error) {
        fprintf(stderr, "LAB: cycle error %s:%ld: %s\n", error.domain.UTF8String, (long)error.code, error.localizedDescription.UTF8String);
        exit(13);
    }
    // A successful cycle alone is not proof of installation: the shell
    // separately checks version and code signature on disk.
    fprintf(stderr, "LAB: update cycle ended\n");
    exit(0);
}
@end

int main(int argc, const char **argv) {
    @autoreleasepool {
        if (argc != 2) return 2;
        NSString *path = [NSString stringWithUTF8String:argv[1]];
        NSBundle *bundle = [NSBundle bundleWithPath:path];
        if (!bundle || ![bundle.bundleIdentifier hasPrefix:@"org.macsync.ci.install-lab"]) return 3;
        NSString *feed = [bundle objectForInfoDictionaryKey:@"SUFeedURL"];
        NSURL *url = [NSURL URLWithString:feed];
        if (![url.scheme isEqualToString:@"http"] || ![url.host isEqualToString:@"127.0.0.1"]) return 4;
        LabDriver *driver = [LabDriver new];
        SPUUpdater *updater = [[SPUUpdater alloc] initWithHostBundle:bundle applicationBundle:bundle userDriver:driver delegate:driver];
        NSError *error = nil;
        if (![updater startUpdater:&error]) {
            fprintf(stderr, "LAB: startup failure: %s\n", error.localizedDescription.UTF8String);
            return 5;
        }
        updater.automaticallyChecksForUpdates = NO;
        updater.automaticallyDownloadsUpdates = NO;
        [updater checkForUpdates];
        [[NSRunLoop currentRunLoop] run];
        // Retain the weak delegate and updater for the entire update cycle.
        (void)driver;
        (void)updater;
        return 6;
    }
}
