// What your Instagram export says about each account: when you followed
// it and it you, and how much you have liked, commented, watched and
// written. Instagram's app does not hold any of that, so it is read in from
// a file: ohrt/tools/export.py makes one from an export on a computer, and
// it is picked here from the Files app. It holds dates and counts only, and
// it stays in the app's own folder on this phone.
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

// Checks a picked file and keeps it. Returns what to tell the user.
static NSString *OhrtExportKeep(NSURL *url) {
    BOOL scoped = [url startAccessingSecurityScopedResource];
    NSData *data = [NSData dataWithContentsOfURL:url];
    if (scoped) [url stopAccessingSecurityScopedResource];
    id read = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![read isKindOfClass:[NSDictionary class]] || ![read[kOhrtFactsFileMark] isKindOfClass:[NSNumber class]] || ![read[@"people"] isKindOfClass:[NSDictionary class]]) {
        return @"That is not a facts file. Make one from your export with ohrt/tools/export.py and pick the file it writes.";
    }
    if ([read[kOhrtFactsFileMark] integerValue] != 1) return @"That facts file was made by a newer export.py than this app knows how to read.";
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
    __block NSString *message = nil;
    if (!OhrtTry(@"export", ^{
            message = OhrtExportKeep(url);
        })) message = @"The file could not be read.";
    // The picker is still on its way out.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        OhrtExportSay(message);
    });
}

@end

void OhrtExportImport(void) {
    UIViewController *top = topMostController();
    if (!top) return;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // The older way of asking for a file, which needs nothing linked in
    // that the tweak does not already have.
    UIDocumentPickerViewController *picker = [[UIDocumentPickerViewController alloc] initWithDocumentTypes:@[ @"public.json", @"public.text", @"public.data" ]
                                                                                                    inMode:UIDocumentPickerModeImport];
#pragma clang diagnostic pop
    picker.delegate = [OhrtExportPicker shared];
    picker.allowsMultipleSelection = NO;
    [top presentViewController:picker animated:YES completion:nil];
}
