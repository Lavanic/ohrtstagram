// What your Instagram export says about each account: when you followed
// it and it you, and how much you have liked, commented, watched and
// written. Instagram's app does not hold any of that, so it is read in:
// either the unpacked export itself, picked as a folder in the Files app
// and read here (OhrtExportReader.m), or the one file ohrt/tools/export.py
// makes from it on a computer. What is kept is dates and counts only, in
// the app's own folder on this phone.
//
// The file belongs to one account, and is kept and looked up under the
// account that is signed in.
#import "../../src/Utils.h"
#import "Ohrt.h"

static NSString *const kOhrtFactsFileMark = @"ohrtstagram_facts";

static NSString *OhrtExportText(id value) {
    if ([value isKindOfClass:[NSString class]]) return value;
    if ([value isKindOfClass:[NSNumber class]]) return [value stringValue];
    return nil;
}

static id OhrtExportUser(void) {
    return OhrtCall(OhrtCurrentSession(), @"user");
}

static NSString *OhrtExportPath(NSString *account) {
    NSString *support = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    return [[support stringByAppendingPathComponent:@"ohrt"] stringByAppendingPathComponent:[NSString stringWithFormat:@"export-%@.json", account]];
}

static NSMutableDictionary<NSString *, id> *gOhrtExports;

// The export read in for the account that is signed in, or nil. Main thread.
static NSDictionary *OhrtExport(void) {
    NSString *account = OhrtExportText(OhrtCall(OhrtExportUser(), @"pk"));
    if (!account.length) return nil;
    if (!gOhrtExports) gOhrtExports = [NSMutableDictionary dictionary];
    id held = gOhrtExports[account];
    if (!held) {
        NSData *data = [NSData dataWithContentsOfFile:OhrtExportPath(account)];
        id read = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        held = [read isKindOfClass:[NSDictionary class]] ? read : [NSNull null];
        gOhrtExports[account] = held;
        if (held != [NSNull null]) OhrtLog(@"export: %lu accounts on file", (unsigned long)[held[@"people"] count]);
    }
    return held == [NSNull null] ? nil : held;
}

NSDictionary *OhrtExportPerson(NSString *username) {
    if (!username.length) return nil;
    id people = OhrtExport()[@"people"];
    id person = [people isKindOfClass:[NSDictionary class]] ? people[username.lowercaseString] : nil;
    return [person isKindOfClass:[NSDictionary class]] ? person : nil;
}

// Conversations are filed under the other person's name as they show it,
// which is all the export gives. A name that more than one conversation
// carries could be either person, so it is not used.
NSDictionary *OhrtExportThread(NSString *fullName) {
    if (!fullName.length) return nil;
    id threads = OhrtExport()[@"threads"];
    id thread = [threads isKindOfClass:[NSDictionary class]] ? threads[fullName] : nil;
    if (![thread isKindOfClass:[NSDictionary class]] || [thread[@"threads"] integerValue] != 1) return nil;
    return thread;
}

static NSString *OhrtExportDay(NSTimeInterval seconds) {
    NSDateFormatter *formatter = [NSDateFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    formatter.dateFormat = @"yyyy-MM-dd";
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:seconds]];
}

// When the export on file was made, in seconds since 1970, or 0 with none.
NSTimeInterval OhrtExportDate(void) {
    return [OhrtExport()[@"exported"] doubleValue];
}

NSString *OhrtExportStatus(void) {
    NSDictionary *export = OhrtExport();
    if (!export) return @"None read in yet";
    return [NSString stringWithFormat:@"%lu accounts, exported %@", (unsigned long)[export[@"people"] count], OhrtExportDay([export[@"exported"] doubleValue])];
}

static void OhrtExportSay(NSString *message) {
    UIViewController *top = topMostController();
    if (!top) return;
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Your Insta⁠gram export" message:message preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [top presentViewController:alert animated:YES completion:nil];
}

// Checks what was read from a picked folder or file and keeps it. Returns
// what to tell the user. Main thread.
static NSString *OhrtExportKeep(id read) {
    if (![read isKindOfClass:[NSDictionary class]] || ![read[kOhrtFactsFileMark] isKindOfClass:[NSNumber class]] || ![read[@"people"] isKindOfClass:[NSDictionary class]]) {
        return @"That is neither an unpacked Insta\u2060gram export nor a facts file made from one. Unpack the export's zip in Files, then pick the folder it makes.";
    }
    if ([read[kOhrtFactsFileMark] integerValue] != 1) return @"That facts file was made by a newer export.py than this app knows how to read.";
    if (![read[@"people"] count]) return @"Nothing about any account was found in there. Ask for the export as JSON, with followers and following in it.";
    NSData *data = [NSJSONSerialization dataWithJSONObject:read options:0 error:nil];
    if (!data) return @"What was read could not be kept.";
    id user = OhrtExportUser();
    NSString *account = OhrtExportText(OhrtCall(user, @"pk"));
    NSString *username = OhrtExportText(OhrtCall(user, @"username")).lowercaseString;
    if (!account.length) return @"Could not tell which account is signed in, so nothing was read in.";
    NSString *theirs = OhrtExportText(read[@"account"]).lowercaseString;
    if (theirs.length && username.length && ![theirs isEqualToString:username]) {
        return [NSString stringWithFormat:@"That export is %@'s and you are signed in as %@. Nothing was read in.", theirs, username];
    }
    NSString *path = OhrtExportPath(account);
    [[NSFileManager defaultManager] createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
    if (![data writeToFile:path atomically:YES]) return @"The file could not be kept on this phone.";
    [gOhrtExports removeObjectForKey:account];
    OhrtLog(@"export: read in, %lu accounts and %lu conversations", (unsigned long)[read[@"people"] count], (unsigned long)[read[@"threads"] count]);
    return [NSString stringWithFormat:@"Read in %lu accounts and %lu conversations, exported %@. Profiles show them from the next one you open.",
                                      (unsigned long)[read[@"people"] count], (unsigned long)[read[@"threads"] count], OhrtExportDay([read[@"exported"] doubleValue])];
}

@interface OhrtExportPicker : NSObject <UIDocumentPickerDelegate>
@end

@implementation OhrtExportPicker

+ (instancetype)shared {
    static OhrtExportPicker *shared;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [OhrtExportPicker new];
    });
    return shared;
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSURL *url = urls.firstObject;
    if (!url) return;
    // A whole export has tens of megabytes of likes in it, so it is read
    // off the main thread, with a note up meanwhile.
    UIAlertController *wait = [UIAlertController alertControllerWithTitle:@"Reading your export" message:@"This can take a minute." preferredStyle:UIAlertControllerStyleAlert];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [topMostController() presentViewController:wait animated:YES completion:nil];
    });
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        __block id read = nil;
        BOOL scoped = [url startAccessingSecurityScopedResource];
        OhrtTry(@"export", ^{
            BOOL folder = NO;
            if ([[NSFileManager defaultManager] fileExistsAtPath:url.path isDirectory:&folder] && folder) {
                read = OhrtReadExportFolder(url);
            } else {
                NSData *data = [NSData dataWithContentsOfURL:url];
                read = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            }
        });
        if (scoped) [url stopAccessingSecurityScopedResource];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.2 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            __block NSString *message = @"That could not be read.";
            OhrtTry(@"export", ^{
                message = OhrtExportKeep(read);
            });
            void (^say)(void) = ^{
                OhrtExportSay(message);
            };
            if (wait.presentingViewController) [wait dismissViewControllerAnimated:YES completion:say];
            else say();
        });
    });
}

@end

void OhrtExportImport(void) {
    UIViewController *top = topMostController();
    if (!top) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // The older way of asking for a file, which needs nothing linked in
    // that the tweak does not already have. Opened in place, because a
    // folder cannot be copied in the way a single file can.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.folder", @"public.json" ]
                                                                                                    inMode:UIDocumentPickerModeOpen];
#pragma clang diagnostic pop
    picker.delegate = [OhrtExportPicker shared];
    picker.allowsMultipleSelection = NO;
    [top presentViewController:picker animated:YES completion:nil];
}
